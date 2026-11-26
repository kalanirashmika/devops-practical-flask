import 'features.dart';

/// Technique 1 - fixed, rule-based thresholds on motion magnitude.
///
/// A fall looks like: (optional) free-fall dip -> impact spike -> the phone
/// lying still in a new orientation. Each stage is scored 0..1 and combined.
class ThresholdDetector {
  static const double impactStartG = 1.8;
  static const double impactFullG = 3.0;
  static const double freeFallStartG = 0.7;
  static const double freeFallFullG = 0.3;
  static const double stillStartStd = 1.0;
  static const double stillFullStd = 0.3;
  static const double tiltStartRad = 0.4;
  static const double tiltFullRad = 1.0;

  /// Absolute "phone is not moving" rule used for the prolonged-stop check.
  static const double restStd = 0.35;
  static const double restSma = 0.6;

  double fallConfidence(WindowFeatures f) {
    final impact = ramp(f.maxMagG, impactStartG, impactFullG);
    final freeFall = ramp(f.minMagG, freeFallStartG, freeFallFullG);
    final still = ramp(f.tailStd, stillStartStd, stillFullStd);
    final tilt = ramp(f.tiltChange, tiltStartRad, tiltFullRad);

    var score = 0.45 * impact + 0.15 * freeFall + 0.20 * still + 0.20 * tilt;
    // No real impact -> cannot be a fall, however still the phone is.
    if (impact < 0.2 && score > 0.3) score = 0.3;
    // Still moving hard after the spike (running, jumping) -> not a fall.
    if (still < 0.2 && score > 0.45) score = 0.45;
    return score;
  }

  bool isAtRest(WindowFeatures f) => f.tailStd < restStd && f.tailSma < restSma;

  /// Confidence that a stop has lasted abnormally long.
  double stopConfidence(double stillSeconds, {required double warnAfter, required double alarmAfter}) =>
      ramp(stillSeconds, warnAfter, alarmAfter);
}
