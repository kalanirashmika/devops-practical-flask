import 'dart:collection';

import 'fall_model.dart';
import 'features.dart';
import 'fusion.dart';
import 'sensor_sample.dart';
import 'statistical_detector.dart';
import 'threshold_detector.dart';

/// Tunable behaviour of the engine (driven by the Settings screen).
class EngineConfig {
  /// Fused confidence needed to raise an alarm (lower = more sensitive).
  final double triggerLevel;

  /// A stop starts to look suspicious after this many seconds...
  final double stopWarnSeconds;

  /// ...and is treated as abnormal after this many.
  final double stopAlarmSeconds;

  const EngineConfig({
    this.triggerLevel = 0.60,
    this.stopWarnSeconds = 45,
    this.stopAlarmSeconds = 90,
  });

  /// 0 = low, 1 = medium, 2 = high sensitivity.
  factory EngineConfig.forSensitivity(int sensitivity, {double stopAlarmSeconds = 90}) {
    const levels = [0.70, 0.60, 0.50];
    return EngineConfig(
      triggerLevel: levels[sensitivity.clamp(0, 2)],
      stopWarnSeconds: stopAlarmSeconds / 2,
      stopAlarmSeconds: stopAlarmSeconds,
    );
  }
}

/// What the engine concluded for the most recent analysis step.
class EngineSnapshot {
  final WindowFeatures features;
  final FusionResult fusion;
  final bool walking;
  final bool atRest;
  final double stillSeconds;
  final int baselineWindows;

  const EngineSnapshot({
    required this.features,
    required this.fusion,
    required this.walking,
    required this.atRest,
    required this.stillSeconds,
    required this.baselineWindows,
  });
}

/// Multi-method motion analysis engine.
///
/// Feed it fixed-rate samples with [addSample]; every half second (once a
/// full 3 s window is available) it runs the threshold, statistical and ML
/// detectors and fuses them into one confidence value.
class DetectionEngine {
  final FallModel model;
  EngineConfig config;

  final ThresholdDetector thresholdDetector = ThresholdDetector();
  final StatisticalDetector statisticalDetector = StatisticalDetector();
  final ConfidenceFusion _fusion = ConfidenceFusion();

  final int windowSamples;
  final int hopSamples;
  final ListQueue<SensorSample> _window = ListQueue<SensorSample>();
  int _sinceLast = 0;

  /// Seconds of walking seen recently; a stop only counts after real walking.
  double _walkSeconds = 0;
  double _stillRule = 0;
  double _stillStat = 0;
  bool _armed = true;
  int _cooldownHops = 0;

  static const double _minWalkBeforeStop = 8;

  DetectionEngine({
    required this.model,
    this.config = const EngineConfig(),
    this.windowSamples = kWindowSamples,
    this.hopSamples = kSampleRateHz ~/ 2,
  });

  double get _hopSeconds => hopSamples / kSampleRateHz;
  bool get armed => _armed;

  /// Returns a snapshot when a new analysis step ran, otherwise null.
  EngineSnapshot? addSample(SensorSample sample) {
    _window.addLast(sample);
    if (_window.length > windowSamples) _window.removeFirst();
    _sinceLast++;
    if (_window.length < windowSamples || _sinceLast < hopSamples) return null;
    _sinceLast = 0;
    return _analyse();
  }

  EngineSnapshot _analyse() {
    final f = WindowFeatures.fromSamples(_window.toList(growable: false));

    final walking = f.tailSma > 1.0 && f.tailStd > 0.5;
    final restRule = thresholdDetector.isAtRest(f);
    final restStat = statisticalDetector.isAtRest(f);

    if (walking) {
      _walkSeconds = (_walkSeconds + _hopSeconds).clamp(0, 60);
      _stillRule = 0;
      _stillStat = 0;
    } else if (_walkSeconds >= _minWalkBeforeStop) {
      _stillRule = restRule ? _stillRule + _hopSeconds : (_stillRule - _hopSeconds).clamp(0, double.infinity);
      _stillStat = restStat ? _stillStat + _hopSeconds : (_stillStat - _hopSeconds).clamp(0, double.infinity);
    }

    final fall = DetectorScores(
      threshold: thresholdDetector.fallConfidence(f),
      statistical: statisticalDetector.fallConfidence(f),
      ml: model.predict(f.mlVector),
    );
    var result = _fusion.fuse(
      fall: fall,
      stopThreshold: thresholdDetector.stopConfidence(
        _stillRule,
        warnAfter: config.stopWarnSeconds,
        alarmAfter: config.stopAlarmSeconds,
      ),
      stopStatistical: statisticalDetector.stopConfidence(
        _stillStat,
        warnAfter: config.stopWarnSeconds,
        alarmAfter: config.stopAlarmSeconds,
      ),
      triggerLevel: config.triggerLevel,
    );

    // Only ordinary walking may update the user's personal baseline.
    if (walking && result.fallConfidence < 0.3 && f.maxMagG < 2.2) {
      statisticalDetector.learn(f);
    }

    if (_cooldownHops > 0) _cooldownHops--;
    if (result.triggered && (!_armed || _cooldownHops > 0)) {
      result = FusionResult(
        fall: result.fall,
        stopThreshold: result.stopThreshold,
        stopStatistical: result.stopStatistical,
        fallConfidence: result.fallConfidence,
        stopConfidence: result.stopConfidence,
        fallAgreeing: result.fallAgreeing,
        triggered: false,
        type: AnomalyType.none,
      );
    } else if (result.triggered) {
      _armed = false; // one alarm at a time, until resume() is called
    }

    return EngineSnapshot(
      features: f,
      fusion: result,
      walking: walking,
      atRest: restRule,
      stillSeconds: _stillRule > _stillStat ? _stillRule : _stillStat,
      baselineWindows: statisticalDetector.baselineWindows,
    );
  }

  /// Re-arm after an alarm was cancelled or handled.
  void resume({double cooldownSeconds = 8}) {
    _armed = true;
    _stillRule = 0;
    _stillStat = 0;
    _walkSeconds = 0;
    _cooldownHops = (cooldownSeconds / _hopSeconds).ceil();
    _window.clear();
    _sinceLast = 0;
  }
}
