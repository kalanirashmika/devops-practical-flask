import 'dart:math' as math;

import 'features.dart';
import 'sensor_sample.dart';

/// Turns the two raw sensor streams (which arrive at device-dependent rates)
/// into fixed-rate [SensorSample]s.
///
/// Call [onAccelerometer]/[onGyroscope] from the sensor listeners and [tick]
/// every 20 ms. Between ticks the most extreme reading is held, so a short
/// impact spike that falls between two ticks is not lost.
class MotionSampler {
  List<double> _acc = const [0, 0, kGravity];
  List<double> _gyro = const [0, 0, 0];
  List<double>? _peakAcc;
  double _peakDeviation = -1;
  List<double>? _peakGyro;
  double _peakGyroMag = -1;
  bool hasData = false;

  void onAccelerometer(double x, double y, double z) {
    hasData = true;
    _acc = [x, y, z];
    final deviation = (math.sqrt(x * x + y * y + z * z) - kGravity).abs();
    if (deviation > _peakDeviation) {
      _peakDeviation = deviation;
      _peakAcc = _acc;
    }
  }

  void onGyroscope(double x, double y, double z) {
    _gyro = [x, y, z];
    final mag = math.sqrt(x * x + y * y + z * z);
    if (mag > _peakGyroMag) {
      _peakGyroMag = mag;
      _peakGyro = _gyro;
    }
  }

  SensorSample tick(int tMs) {
    final a = _peakAcc ?? _acc;
    final g = _peakGyro ?? _gyro;
    _peakAcc = null;
    _peakDeviation = -1;
    _peakGyro = null;
    _peakGyroMag = -1;
    return SensorSample(tMs: tMs, ax: a[0], ay: a[1], az: a[2], gx: g[0], gy: g[1], gz: g[2]);
  }
}
