import 'dart:math' as math;

import 'features.dart';
import 'sensor_sample.dart';

/// Generates realistic-looking motion data without a phone being moved.
///
/// Used by the "Simulate a fall" demo button (so the detection pipeline can
/// be demonstrated safely) and by the unit tests.
class SyntheticMotion {
  final math.Random _rng;
  SyntheticMotion([int seed = 46]) : _rng = math.Random(seed);

  static const double _dt = 1 / kSampleRateHz;
  static const List<double> pocket = [0.10, 0.90, 0.42]; // upright in a pocket
  static const List<double> onGround = [0.85, 0.05, 0.52]; // lying on its side

  double _gauss() {
    final u1 = 1 - _rng.nextDouble();
    final u2 = _rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  static List<double> _unit(List<double> v) {
    final n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / n, v[1] / n, v[2] / n];
  }

  SensorSample _sample(List<double> acc, List<double> gyro) => SensorSample(
        tMs: 0,
        ax: acc[0],
        ay: acc[1],
        az: acc[2],
        gx: gyro[0],
        gy: gyro[1],
        gz: gyro[2],
      );

  List<SensorSample> walking(double seconds, {double amp = 2.5, double freq = 1.9, double noise = 0.3}) {
    final g = _unit(pocket);
    const side = [0.97, -0.17, 0.13];
    final n = (seconds * kSampleRateHz).round();
    return List.generate(n, (i) {
      final t = i * _dt;
      final step = amp * (math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(4 * math.pi * freq * t + 0.6));
      final sway = amp * 0.45 * math.sin(math.pi * freq * t);
      final swing = 0.8 * math.sin(math.pi * freq * t);
      return _sample([
        for (var k = 0; k < 3; k++) g[k] * (kGravity + step) + side[k] * sway + noise * _gauss(),
      ], [
        swing * 0.6 + 0.08 * _gauss(),
        swing * 0.3 + 0.08 * _gauss(),
        swing * 0.2 + 0.08 * _gauss(),
      ]);
    });
  }

  List<SensorSample> running(double seconds) => walking(seconds, amp: 9, freq: 2.8, noise: 0.5);

  List<SensorSample> still(double seconds, {List<double> orientation = pocket, double noise = 0.06}) {
    final g = _unit(orientation);
    final n = (seconds * kSampleRateHz).round();
    return List.generate(
      n,
      (_) => _sample(
        [for (var k = 0; k < 3; k++) g[k] * kGravity + noise * _gauss()],
        [0.02 * _gauss(), 0.02 * _gauss(), 0.02 * _gauss()],
      ),
    );
  }

  /// Free-fall dip, hard impact, then lying still in a new orientation.
  List<SensorSample> fall({double stillSeconds = 4, double impactG = 4.2}) {
    final g = _unit(pocket);
    final out = <SensorSample>[];
    for (var i = 0; i < 15; i++) {
      out.add(_sample(
        [for (var k = 0; k < 3; k++) g[k] * kGravity * 0.25 + 0.6 * _gauss()],
        [3.0 + 0.4 * _gauss(), -2.0 + 0.4 * _gauss(), 1.5 + 0.4 * _gauss()],
      ));
    }
    const hit = [0.55, -0.62, 0.56];
    for (var i = 0; i < 3; i++) {
      out.add(_sample(
        [for (var k = 0; k < 3; k++) hit[k] * kGravity * impactG + 2.0 * _gauss()],
        [5.5, -4.0, 3.0],
      ));
    }
    final rest = still(stillSeconds, orientation: onGround);
    for (var i = 0; i < 12 && i < rest.length; i++) {
      final fade = 2.0 * (1 - i / 12);
      final s = rest[i];
      rest[i] = _sample(
        [s.ax + fade * _gauss(), s.ay + fade * _gauss(), s.az + fade * _gauss()],
        [s.gx, s.gy, s.gz],
      );
    }
    return out..addAll(rest);
  }

  /// A short knock (phone bumped) while the person simply keeps walking.
  List<SensorSample> bumpWhileWalking(double seconds) {
    final w = walking(seconds);
    final at = w.length ~/ 2;
    final g = _unit(pocket);
    for (var i = at; i < at + 3 && i < w.length; i++) {
      final s = w[i];
      w[i] = _sample([s.ax + g[0] * 11, s.ay + g[1] * 11, s.az + g[2] * 11], [s.gx, s.gy, s.gz]);
    }
    return w;
  }
}
