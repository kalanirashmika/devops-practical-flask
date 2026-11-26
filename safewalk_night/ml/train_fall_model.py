"""Train the SafeWalk Night on-device fall classifier.

Synthetic 3-second accelerometer + gyroscope windows (50 Hz) are simulated for
normal activity (walking, running, standing, stopping, phone handling, sitting
down, bumps) and for falls (hard fall, fall with struggle, soft collapse).
Ten hand-crafted features are extracted per window - the SAME features the
Dart app computes in lib/detection/features.dart - and a small MLP is trained.

Outputs:
  fall_model.tflite      - TensorFlow Lite model (input: 10 raw features)
  fall_model.json        - same weights for the pure-Dart fallback
  parity_fixture.json    - raw windows + expected features/probabilities,
                           used by the Dart unit tests to prove parity
"""
import json
import numpy as np
import tensorflow as tf

FS = 50
N = 150  # 3 s
G = 9.80665
rng = np.random.default_rng(46)


def rand_unit():
    v = rng.normal(size=3)
    return v / np.linalg.norm(v)


def rotate_towards(a, b, t):
    """Blend unit vector a towards b (t in 0..1), renormalised."""
    v = (1 - t) * a + t * b
    n = np.linalg.norm(v)
    return v / n if n > 1e-6 else a


def gait(n, amp, freq, phase=None):
    t = np.arange(n) / FS
    ph = rng.uniform(0, 2 * np.pi) if phase is None else phase
    base = np.sin(2 * np.pi * freq * t + ph)
    harm = 0.35 * np.sin(4 * np.pi * freq * t + ph * 1.7)
    return amp * (base + harm)


def walking(n, amp=None, freq=None, grav=None):
    amp = rng.uniform(1.5, 4.0) if amp is None else amp
    freq = rng.uniform(1.6, 2.2) if freq is None else freq
    grav = rand_unit() if grav is None else grav
    acc = np.outer(np.ones(n), grav * G)
    acc += np.outer(gait(n, amp, freq), grav)
    side = np.cross(grav, rand_unit())
    side /= np.linalg.norm(side)
    acc += np.outer(gait(n, amp * rng.uniform(0.3, 0.6), freq / 2), side)
    acc += rng.normal(scale=rng.uniform(0.15, 0.5), size=(n, 3))
    gyro = np.outer(gait(n, rng.uniform(0.3, 1.5), freq / 2), rand_unit())
    gyro += rng.normal(scale=0.08, size=(n, 3))
    return acc, gyro, grav


def still(n, grav=None, noise=None):
    grav = rand_unit() if grav is None else grav
    noise = rng.uniform(0.03, 0.2) if noise is None else noise
    acc = np.outer(np.ones(n), grav * G) + rng.normal(scale=noise, size=(n, 3))
    gyro = rng.normal(scale=0.02, size=(n, 3))
    return acc, gyro, grav


def sim_walk():
    a, g, _ = walking(N)
    return a, g


def sim_run():
    a, g, _ = walking(N, amp=rng.uniform(6, 12), freq=rng.uniform(2.5, 3.2))
    return a, g


def sim_still():
    a, g, _ = still(N)
    return a, g


def sim_walk_then_stop():
    k = int(rng.uniform(0.25, 0.7) * N)
    a1, g1, grav = walking(k)
    a2, g2, _ = still(N - k, grav=rotate_towards(grav, rand_unit(), rng.uniform(0, 0.12)))
    return np.vstack([a1, a2]), np.vstack([g1, g2])


def sim_bump():
    a, g, grav = walking(N)
    i = int(rng.uniform(0.15, 0.85) * N)
    w = rng.integers(2, 4)
    a[i:i + w] += grav * rng.uniform(6, 14)
    g[i:i + w] += rng.normal(scale=1.0, size=(len(g[i:i + w]), 3))
    return a, g


def sim_handling():
    """Phone taken out of the pocket / turned in the hand while walking on."""
    a, g, grav = walking(N, amp=rng.uniform(1.0, 2.5))
    i = int(rng.uniform(0.15, 0.6) * N)
    dur = int(rng.uniform(0.4, 1.0) * FS)
    new = rand_unit()
    for j in range(i, N):
        t = min(1.0, (j - i) / dur)
        gv = rotate_towards(grav, new, t)
        a[j] += (gv - grav) * G
    g[i:i + dur] += np.outer(np.ones(len(g[i:i + dur])), rand_unit() * rng.uniform(1.5, 4.0))
    a[i:i + dur] += rng.normal(scale=rng.uniform(0.8, 2.0), size=(len(a[i:i + dur]), 3))
    return a, g


def sim_sit_down():
    k = int(rng.uniform(0.2, 0.5) * N)
    a1, g1, grav = walking(k, amp=rng.uniform(1.0, 2.5))
    rest = N - k
    new = rotate_towards(grav, rand_unit(), rng.uniform(0.2, 0.5))
    a2, g2, _ = still(rest, grav=new, noise=rng.uniform(0.05, 0.25))
    d = min(rest, int(rng.uniform(0.3, 0.6) * FS))
    a2[:d] += np.outer(np.sin(np.linspace(0, np.pi, d)) * rng.uniform(-4, -1.5), new)
    if d + 3 <= rest:
        a2[d:d + 3] += new * rng.uniform(2, 5)
    g2[:d] += np.outer(np.ones(d), rand_unit() * rng.uniform(0.5, 1.8))
    return np.vstack([a1, a2]), np.vstack([g1, g2])


def sim_fall(kind="hard"):
    k = int(rng.uniform(0.2, 0.6) * N)
    a1, g1, grav = walking(k)
    ff = int(rng.uniform(0.18, 0.4) * FS) if kind != "soft" else int(rng.uniform(0.3, 0.6) * FS)
    imp = int(rng.integers(2, 5))
    rest = N - k - ff - imp
    if rest < FS:  # keep >= 1 s after impact
        return sim_fall(kind)
    lvl = rng.uniform(0.08, 0.45) if kind != "soft" else rng.uniform(0.45, 0.75)
    a_ff = np.outer(np.ones(ff), grav * G * lvl) + rng.normal(scale=0.6, size=(ff, 3))
    g_ff = np.outer(np.ones(ff), rand_unit() * rng.uniform(1.5, 5.0)) + rng.normal(scale=0.4, size=(ff, 3))
    peak = rng.uniform(2.6, 6.0) if kind != "soft" else rng.uniform(1.8, 2.7)
    a_imp = np.outer(np.ones(imp), rand_unit() * G * peak) + rng.normal(scale=2.0, size=(imp, 3))
    g_imp = np.outer(np.ones(imp), rand_unit() * rng.uniform(3.0, 8.0))
    tilt_mix = rng.uniform(0.55, 1.0)
    new = rotate_towards(grav, rand_unit(), tilt_mix)
    noise = rng.uniform(0.03, 0.2) if kind != "struggle" else rng.uniform(0.3, 0.8)
    a3, g3, _ = still(rest, grav=new, noise=noise)
    b = min(rest, int(0.25 * FS))  # settling bounce
    a3[:b] += rng.normal(scale=rng.uniform(1.0, 3.0), size=(b, 3)) * np.linspace(1, 0, b)[:, None]
    if kind == "struggle":
        g3 += rng.normal(scale=0.4, size=g3.shape)
    return np.vstack([a1, a_ff, a_imp, a3]), np.vstack([g1, g_ff, g_imp, g3])


def features(acc, gyro):
    """Must stay identical to lib/detection/features.dart (mlVector)."""
    mag = np.linalg.norm(acc, axis=1)
    mean_axis = acc.mean(axis=0)
    sma = np.mean(np.sum(np.abs(acc - mean_axis), axis=1))
    d = np.abs(np.diff(mag)) * FS
    gmag = np.linalg.norm(gyro, axis=1)
    head = acc[:25].mean(axis=0)
    tail = acc[-25:].mean(axis=0)
    cosang = np.dot(head, tail) / (np.linalg.norm(head) * np.linalg.norm(tail) + 1e-9)
    tilt = float(np.arccos(np.clip(cosang, -1.0, 1.0)))
    return np.array([
        mag.max() / G,
        mag.min() / G,
        mag.std(),
        sma,
        d.max() / 100.0,
        d.mean() / 100.0,
        gmag.max(),
        mag[-50:].std(),
        mag[:50].std(),
        tilt,
    ], dtype=np.float64)


NEG = [(sim_walk, 3), (sim_run, 2), (sim_still, 2), (sim_walk_then_stop, 3),
       (sim_bump, 2), (sim_handling, 3), (sim_sit_down, 3)]
POS = [(lambda: sim_fall("hard"), 4), (lambda: sim_fall("struggle"), 3), (lambda: sim_fall("soft"), 3)]


def build(n_per_unit):
    X, y, raw = [], [], []
    for fns, label in ((NEG, 0), (POS, 1)):
        for fn, w in fns:
            for _ in range(n_per_unit * w):
                a, g = fn()
                assert a.shape == (N, 3) and g.shape == (N, 3), (a.shape, g.shape)
                X.append(features(a, g))
                y.append(label)
                raw.append((a, g))
    return np.array(X), np.array(y, dtype=np.float32), raw


X, y, _ = build(600)
Xt, yt, raw_t = build(120)
print("train", X.shape, "pos rate", y.mean(), "| test", Xt.shape)

mu = X.mean(axis=0)
sd = X.std(axis=0) + 1e-6

tf.keras.utils.set_random_seed(46)
inp = tf.keras.Input(shape=(10,), name="features")
h = tf.keras.layers.Lambda(lambda t: (t - tf.constant(mu, tf.float32)) / tf.constant(sd, tf.float32))(inp)
h = tf.keras.layers.Dense(16, activation="relu", name="d1")(h)
h = tf.keras.layers.Dense(8, activation="relu", name="d2")(h)
out = tf.keras.layers.Dense(1, activation="sigmoid", name="out")(h)
model = tf.keras.Model(inp, out)
model.compile(optimizer=tf.keras.optimizers.Adam(0.003), loss=tf.keras.losses.BinaryCrossentropy(label_smoothing=0.05), metrics=["accuracy"])
model.fit(X.astype(np.float32), y, epochs=40, batch_size=64, verbose=0,
          validation_data=(Xt.astype(np.float32), yt))

p = model.predict(Xt.astype(np.float32), verbose=0).ravel()
pred = p >= 0.5
tp = int(((pred == 1) & (yt == 1)).sum()); fp = int(((pred == 1) & (yt == 0)).sum())
fn = int(((pred == 0) & (yt == 1)).sum()); tn = int(((pred == 0) & (yt == 0)).sum())
metrics = {
    "test_samples": int(len(yt)), "accuracy": round((tp + tn) / len(yt), 4),
    "precision": round(tp / max(1, tp + fp), 4), "recall": round(tp / max(1, tp + fn), 4),
    "tp": tp, "fp": fp, "fn": fn, "tn": tn,
}
print(metrics)

conv = tf.lite.TFLiteConverter.from_keras_model(model)
tfl = conv.convert()
open("fall_model.tflite", "wb").write(tfl)

interp = tf.lite.Interpreter(model_content=tfl)
interp.allocate_tensors()
i_d = interp.get_input_details()[0]; o_d = interp.get_output_details()[0]
print("tflite in", i_d["shape"], i_d["dtype"], "out", o_d["shape"])


def tfl_predict(v):
    interp.set_tensor(i_d["index"], v.astype(np.float32).reshape(1, 10))
    interp.invoke()
    return float(interp.get_tensor(o_d["index"]).ravel()[0])


layers = []
for name in ("d1", "d2", "out"):
    w, b = model.get_layer(name).get_weights()
    layers.append({"w": w.T.tolist(), "b": b.tolist()})  # w[out][in]
json.dump({
    "description": "SafeWalk Night fall classifier (10 features -> 16 relu -> 8 relu -> 1 sigmoid)",
    "trained_on": "synthetic simulated motion windows, 50 Hz, 3 s",
    "sample_rate_hz": FS, "window_samples": N,
    "feature_names": ["maxMagG", "minMagG", "stdMag", "sma", "maxJerk", "meanJerk",
                      "maxGyro", "tailStd", "headStd", "tiltChange"],
    "mean": mu.tolist(), "std": sd.tolist(), "layers": layers, "metrics": metrics,
}, open("fall_model.json", "w"))


def dart_like(v):
    x = (v - mu) / sd
    for i, L in enumerate(layers):
        x = np.array(L["w"]) @ x + np.array(L["b"])
        x = np.maximum(x, 0) if i < 2 else 1 / (1 + np.exp(-x))
    return float(x[0])


# Parity fixture: a few raw windows with expected features + probabilities.
idx = [0, 400, 700, 1100, 1500, 1900, 2200, 2400, 2800, 3200]
fx = []
maxdiff = 0.0
for i in idx:
    i = min(i, len(raw_t) - 1)
    a, g = raw_t[i]
    f = features(a, g)
    pk, pt, pd = float(p[i]), tfl_predict(f), dart_like(f)
    maxdiff = max(maxdiff, abs(pk - pt), abs(pk - pd))
    fx.append({"label": int(yt[i]), "acc": np.round(a, 4).tolist(), "gyro": np.round(g, 4).tolist(),
               "features": features(np.round(a, 4), np.round(g, 4)).tolist(),
               "prob": dart_like(features(np.round(a, 4), np.round(g, 4)))})
print("max keras/tflite/dart-like diff:", maxdiff)
json.dump(fx, open("parity_fixture.json", "w"))
print("labels in fixture:", [f["label"] for f in fx], "probs:", [round(f["prob"], 3) for f in fx])
