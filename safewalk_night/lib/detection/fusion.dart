enum AnomalyType { none, fall, prolongedStop }

/// The three detectors' opinions (each 0..1) about one kind of event.
class DetectorScores {
  final double threshold, statistical, ml;
  const DetectorScores({this.threshold = 0, this.statistical = 0, this.ml = 0});
}

class FusionResult {
  final DetectorScores fall;
  final double stopThreshold, stopStatistical;
  final double fallConfidence, stopConfidence;
  final int fallAgreeing;
  final bool triggered;
  final AnomalyType type;

  const FusionResult({
    required this.fall,
    required this.stopThreshold,
    required this.stopStatistical,
    required this.fallConfidence,
    required this.stopConfidence,
    required this.fallAgreeing,
    required this.triggered,
    required this.type,
  });

  double get confidence => fallConfidence > stopConfidence ? fallConfidence : stopConfidence;

  static const FusionResult idle = FusionResult(
    fall: DetectorScores(),
    stopThreshold: 0,
    stopStatistical: 0,
    fallConfidence: 0,
    stopConfidence: 0,
    fallAgreeing: 0,
    triggered: false,
    type: AnomalyType.none,
  );
}

/// Weighted confidence check that combines the three techniques.
///
/// An alarm needs BOTH a high weighted confidence AND at least two detectors
/// independently agreeing - one method on its own can never raise an alarm.
class ConfidenceFusion {
  static const double wThreshold = 0.35;
  static const double wStatistical = 0.25;
  static const double wMl = 0.40;

  /// A detector "agrees" when its own score reaches this level.
  static const double agreeLevel = 0.5;

  FusionResult fuse({
    required DetectorScores fall,
    required double stopThreshold,
    required double stopStatistical,
    required double triggerLevel,
  }) {
    final fallConf = wThreshold * fall.threshold + wStatistical * fall.statistical + wMl * fall.ml;
    final agreeing = [fall.threshold, fall.statistical, fall.ml].where((s) => s >= agreeLevel).length;

    // The ML model only knows falls, so for a prolonged stop the weights are
    // renormalised over the two detectors that can judge it.
    const total = wThreshold + wStatistical;
    final stopConf = (wThreshold * stopThreshold + wStatistical * stopStatistical) / total;
    final stopAgree = stopThreshold >= agreeLevel && stopStatistical >= agreeLevel;

    var type = AnomalyType.none;
    if (fallConf >= triggerLevel && agreeing >= 2) {
      type = AnomalyType.fall;
    } else if (stopConf >= triggerLevel && stopAgree) {
      type = AnomalyType.prolongedStop;
    }
    return FusionResult(
      fall: fall,
      stopThreshold: stopThreshold,
      stopStatistical: stopStatistical,
      fallConfidence: fallConf,
      stopConfidence: stopConf,
      fallAgreeing: agreeing,
      triggered: type != AnomalyType.none,
      type: type,
    );
  }
}
