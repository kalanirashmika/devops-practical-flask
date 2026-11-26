import 'dart:math' as math;

import 'sensor_sample.dart';

const double kGravity = 9.80665;

/// The engine works on fixed-rate data: 50 Hz, 3 second windows.
const int kSampleRateHz = 50;
const int kWindowSamples = 150;

/// Features extracted from one window of motion data.
///
/// The first ten values ([mlVector]) are exactly the features the on-device
/// classifier was trained on (see ml/train_fall_model.py - keep both in sync).
class WindowFeatures {
  /// Peak / lowest acceleration magnitude, in g.
  final double maxMagG, minMagG;

  /// Standard deviation of the acceleration magnitude (m/s^2).
  final double stdMag;

  /// Signal magnitude area of the gravity-removed acceleration (m/s^2).
  final double sma;

  /// Peak / mean jerk of the magnitude signal, in (m/s^3) / 100.
  final double maxJerk, meanJerk;

  /// Peak angular speed (rad/s).
  final double maxGyro;

  /// Std-dev of magnitude over the last / first third of the window.
  final double tailStd, headStd;

  /// Angle (rad) between the phone's orientation at the start and the end.
  final double tiltChange;

  /// Signal magnitude area over the last third only (not an ML input).
  final double tailSma;

  const WindowFeatures({
    required this.maxMagG,
    required this.minMagG,
    required this.stdMag,
    required this.sma,
    required this.maxJerk,
    required this.meanJerk,
    required this.maxGyro,
    required this.tailStd,
    required this.headStd,
    required this.tiltChange,
    required this.tailSma,
  });

  List<double> get mlVector => [
        maxMagG,
        minMagG,
        stdMag,
        sma,
        maxJerk,
        meanJerk,
        maxGyro,
        tailStd,
        headStd,
        tiltChange,
      ];

  static double _std(List<double> v, int from, int to) {
    final n = to - from;
    var mean = 0.0;
    for (var i = from; i < to; i++) {
      mean += v[i];
    }
    mean /= n;
    var acc = 0.0;
    for (var i = from; i < to; i++) {
      final d = v[i] - mean;
      acc += d * d;
    }
    return math.sqrt(acc / n);
  }

  static List<double> _meanAxes(List<SensorSample> w, int from, int to) {
    var x = 0.0, y = 0.0, z = 0.0;
    for (var i = from; i < to; i++) {
      x += w[i].ax;
      y += w[i].ay;
      z += w[i].az;
    }
    final n = to - from;
    return [x / n, y / n, z / n];
  }

  static double _sma(List<SensorSample> w, int from, int to) {
    final m = _meanAxes(w, from, to);
    var acc = 0.0;
    for (var i = from; i < to; i++) {
      acc += (w[i].ax - m[0]).abs() + (w[i].ay - m[1]).abs() + (w[i].az - m[2]).abs();
    }
    return acc / (to - from);
  }

  static WindowFeatures fromSamples(List<SensorSample> w, {int sampleRateHz = kSampleRateHz}) {
    final n = w.length;
    if (n < 12) {
      throw ArgumentError('Need at least 12 samples, got $n');
    }
    final third = n ~/ 3;
    final sixth = n ~/ 6;

    final mag = List<double>.filled(n, 0);
    var maxMag = 0.0, minMag = double.infinity, maxGyro = 0.0;
    for (var i = 0; i < n; i++) {
      final s = w[i];
      final m = math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
      mag[i] = m;
      if (m > maxMag) maxMag = m;
      if (m < minMag) minMag = m;
      final g = math.sqrt(s.gx * s.gx + s.gy * s.gy + s.gz * s.gz);
      if (g > maxGyro) maxGyro = g;
    }

    var maxJerk = 0.0, sumJerk = 0.0;
    for (var i = 1; i < n; i++) {
      final j = (mag[i] - mag[i - 1]).abs() * sampleRateHz;
      if (j > maxJerk) maxJerk = j;
      sumJerk += j;
    }

    final head = _meanAxes(w, 0, sixth);
    final tail = _meanAxes(w, n - sixth, n);
    final dot = head[0] * tail[0] + head[1] * tail[1] + head[2] * tail[2];
    final nh = math.sqrt(head[0] * head[0] + head[1] * head[1] + head[2] * head[2]);
    final nt = math.sqrt(tail[0] * tail[0] + tail[1] * tail[1] + tail[2] * tail[2]);
    final cosAngle = (dot / (nh * nt + 1e-9)).clamp(-1.0, 1.0);

    return WindowFeatures(
      maxMagG: maxMag / kGravity,
      minMagG: minMag / kGravity,
      stdMag: _std(mag, 0, n),
      sma: _sma(w, 0, n),
      maxJerk: maxJerk / 100.0,
      meanJerk: sumJerk / (n - 1) / 100.0,
      maxGyro: maxGyro,
      tailStd: _std(mag, n - third, n),
      headStd: _std(mag, 0, third),
      tiltChange: math.acos(cosAngle),
      tailSma: _sma(w, n - third, n),
    );
  }
}

/// Linear ramp: 0 at [from], 1 at [to] (works in either direction).
double ramp(double value, double from, double to) {
  if (from == to) return value >= to ? 1 : 0;
  return ((value - from) / (to - from)).clamp(0.0, 1.0);
}
