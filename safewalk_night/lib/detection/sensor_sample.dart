/// One fused motion reading: accelerometer (m/s^2, gravity included) and
/// gyroscope (rad/s), resampled to a fixed rate by [MotionSampler].
class SensorSample {
  final int tMs;
  final double ax, ay, az;
  final double gx, gy, gz;

  const SensorSample({
    required this.tMs,
    required this.ax,
    required this.ay,
    required this.az,
    this.gx = 0,
    this.gy = 0,
    this.gz = 0,
  });
}
