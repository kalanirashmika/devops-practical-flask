import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safewalk_night/detection/detection_engine.dart';
import 'package:safewalk_night/detection/fall_model.dart';
import 'package:safewalk_night/detection/features.dart';
import 'package:safewalk_night/detection/fusion.dart';
import 'package:safewalk_night/detection/motion_sampler.dart';
import 'package:safewalk_night/detection/sensor_sample.dart';
import 'package:safewalk_night/detection/statistical_detector.dart';
import 'package:safewalk_night/detection/synthetic_motion.dart';
import 'package:safewalk_night/detection/threshold_detector.dart';

MlpFallModel loadModel() => MlpFallModel.fromJson(File('assets/models/fall_model.json').readAsStringSync());

/// Runs samples through an engine; returns every snapshot produced.
List<EngineSnapshot> run(DetectionEngine engine, List<SensorSample> samples) =>
    [for (final s in samples) engine.addSample(s)].whereType<EngineSnapshot>().toList();

void main() {
  final model = loadModel();

  group('feature extraction + ML model match the Python training code', () {
    final fixture = jsonDecode(File('test/fixtures/parity_fixture.json').readAsStringSync()) as List;

    test('fixture has both normal and fall windows', () {
      expect(fixture.where((e) => e['label'] == 1), isNotEmpty);
      expect(fixture.where((e) => e['label'] == 0), isNotEmpty);
    });

    for (var i = 0; i < fixture.length; i++) {
      test('window $i (label ${fixture[i]['label']})', () {
        final acc = fixture[i]['acc'] as List;
        final gyro = fixture[i]['gyro'] as List;
        final window = [
          for (var k = 0; k < acc.length; k++)
            SensorSample(
              tMs: k * 20,
              ax: (acc[k][0] as num).toDouble(),
              ay: (acc[k][1] as num).toDouble(),
              az: (acc[k][2] as num).toDouble(),
              gx: (gyro[k][0] as num).toDouble(),
              gy: (gyro[k][1] as num).toDouble(),
              gz: (gyro[k][2] as num).toDouble(),
            ),
        ];
        final features = WindowFeatures.fromSamples(window).mlVector;
        final expected = (fixture[i]['features'] as List).cast<num>();
        for (var k = 0; k < expected.length; k++) {
          expect(features[k], closeTo(expected[k].toDouble(), 1e-6), reason: 'feature $k');
        }
        final prob = model.predict(features);
        expect(prob, closeTo((fixture[i]['prob'] as num).toDouble(), 1e-6));
        expect(prob >= 0.5, fixture[i]['label'] == 1);
      });
    }
  });

  group('individual detectors', () {
    final motion = SyntheticMotion(1);
    final walk = WindowFeatures.fromSamples(motion.walking(3));
    final fallWindow = WindowFeatures.fromSamples([...motion.walking(1.4), ...motion.fall(stillSeconds: 1.24)]);

    test('synthetic fall window is exactly one window long', () {
      expect([...motion.walking(1.4), ...motion.fall(stillSeconds: 1.24)].length, kWindowSamples);
    });

    test('threshold detector: fall high, walking low', () {
      final d = ThresholdDetector();
      expect(d.fallConfidence(fallWindow), greaterThan(0.7));
      expect(d.fallConfidence(walk), lessThan(0.3));
    });

    test('statistical detector: fall high, walking low', () {
      final d = StatisticalDetector();
      expect(d.fallConfidence(fallWindow), greaterThan(0.7));
      expect(d.fallConfidence(walk), lessThan(0.3));
    });

    test('statistical detector adapts its baseline to the user', () {
      final d = StatisticalDetector();
      final before = d.baselineSma;
      final vigorous = SyntheticMotion(2).walking(3, amp: 4.5);
      for (var i = 0; i < 60; i++) {
        d.learn(WindowFeatures.fromSamples(vigorous));
      }
      expect(d.baselineWindows, 60);
      expect(d.baselineSma, greaterThan(before));
    });

    test('ML model: fall high, walking low', () {
      expect(model.predict(fallWindow.mlVector), greaterThan(0.8));
      expect(model.predict(walk.mlVector), lessThan(0.2));
    });
  });

  group('confidence fusion', () {
    final fusion = ConfidenceFusion();

    test('weights add up to one', () {
      expect(ConfidenceFusion.wThreshold + ConfidenceFusion.wStatistical + ConfidenceFusion.wMl, closeTo(1, 1e-9));
    });

    test('a single detector alone can never raise an alarm', () {
      for (final scores in const [
        DetectorScores(threshold: 1),
        DetectorScores(statistical: 1),
        DetectorScores(ml: 1),
      ]) {
        final r = fusion.fuse(fall: scores, stopThreshold: 0, stopStatistical: 0, triggerLevel: 0.3);
        expect(r.triggered, isFalse);
      }
    });

    test('two agreeing detectors with enough confidence trigger a fall', () {
      final r = fusion.fuse(
        fall: const DetectorScores(threshold: 0.9, ml: 0.9),
        stopThreshold: 0,
        stopStatistical: 0,
        triggerLevel: 0.6,
      );
      expect(r.fallConfidence, closeTo(0.675, 1e-9));
      expect(r.type, AnomalyType.fall);
    });

    test('prolonged stop needs both stop detectors', () {
      final one = fusion.fuse(fall: const DetectorScores(), stopThreshold: 1, stopStatistical: 0.2, triggerLevel: 0.6);
      expect(one.triggered, isFalse);
      final both = fusion.fuse(fall: const DetectorScores(), stopThreshold: 1, stopStatistical: 1, triggerLevel: 0.6);
      expect(both.type, AnomalyType.prolongedStop);
    });
  });

  group('detection engine end to end', () {
    test('normal walking never raises an alarm', () {
      final engine = DetectionEngine(model: model);
      final snaps = run(engine, SyntheticMotion(3).walking(60));
      expect(snaps, isNotEmpty);
      expect(snaps.any((s) => s.fusion.triggered), isFalse);
      expect(snaps.last.walking, isTrue);
      expect(snaps.last.baselineWindows, greaterThan(50));
    });

    test('running never raises an alarm', () {
      final engine = DetectionEngine(model: model);
      expect(run(engine, SyntheticMotion(4).running(30)).any((s) => s.fusion.triggered), isFalse);
    });

    test('a bump while walking does not raise an alarm', () {
      final engine = DetectionEngine(model: model);
      final m = SyntheticMotion(5);
      final snaps = run(engine, [...m.walking(10), ...m.bumpWhileWalking(6), ...m.walking(6)]);
      expect(snaps.any((s) => s.fusion.triggered), isFalse);
    });

    test('a fall while walking is detected once, with all detectors agreeing', () {
      final engine = DetectionEngine(model: model);
      final m = SyntheticMotion(6);
      final snaps = run(engine, [...m.walking(12), ...m.fall(stillSeconds: 6)]);
      final hits = snaps.where((s) => s.fusion.triggered).toList();
      expect(hits.length, 1);
      expect(hits.single.fusion.type, AnomalyType.fall);
      expect(hits.single.fusion.fallAgreeing, greaterThanOrEqualTo(2));
      expect(hits.single.fusion.fallConfidence, greaterThan(0.6));
      expect(engine.armed, isFalse);
    });

    test('a fall is detected at every sensitivity level', () {
      for (final sensitivity in [0, 1, 2]) {
        final engine = DetectionEngine(model: model, config: EngineConfig.forSensitivity(sensitivity));
        final m = SyntheticMotion(7 + sensitivity);
        final snaps = run(engine, [...m.walking(10), ...m.fall(stillSeconds: 5)]);
        expect(snaps.any((s) => s.fusion.type == AnomalyType.fall), isTrue, reason: 'sensitivity $sensitivity');
      }
    });

    test('a short normal stop does not raise an alarm, a prolonged stop does', () {
      const config = EngineConfig(stopWarnSeconds: 10, stopAlarmSeconds: 20);
      final m = SyntheticMotion(8);

      final short = DetectionEngine(model: model, config: config);
      final shortSnaps = run(short, [...m.walking(15), ...m.still(8), ...m.walking(10)]);
      expect(shortSnaps.any((s) => s.fusion.triggered), isFalse);

      final long = DetectionEngine(model: model, config: config);
      final longSnaps = run(long, [...m.walking(15), ...m.still(30)]);
      final hit = longSnaps.firstWhere((s) => s.fusion.triggered);
      expect(hit.fusion.type, AnomalyType.prolongedStop);
      expect(hit.stillSeconds, greaterThan(10));
    });

    test('standing still without having walked first is not a prolonged stop', () {
      const config = EngineConfig(stopWarnSeconds: 5, stopAlarmSeconds: 10);
      final engine = DetectionEngine(model: model, config: config);
      expect(run(engine, SyntheticMotion(9).still(40)).any((s) => s.fusion.triggered), isFalse);
    });

    test('the "Simulate a fall" demo sequence raises the alarm', () {
      // Same sequence SessionController.simulateFall() replays.
      final engine = DetectionEngine(model: model)..resume(cooldownSeconds: 0);
      final m = SyntheticMotion(11);
      final snaps = run(engine, [...m.walking(5), ...m.fall(stillSeconds: 5)]);
      expect(snaps.where((s) => s.fusion.type == AnomalyType.fall).length, 1);
    });

    test('resume re-arms the engine after a cancelled alarm', () {
      final engine = DetectionEngine(model: model);
      final m = SyntheticMotion(10);
      expect(run(engine, [...m.walking(10), ...m.fall(stillSeconds: 5)]).any((s) => s.fusion.triggered), isTrue);
      engine.resume();
      expect(engine.armed, isTrue);
      final again = run(engine, [...m.walking(15), ...m.fall(stillSeconds: 5)]);
      expect(again.any((s) => s.fusion.type == AnomalyType.fall), isTrue);
    });
  });

  group('motion sampler', () {
    test('holds an impact spike that arrives between two ticks', () {
      final sampler = MotionSampler();
      sampler.onAccelerometer(0, 0, 9.8);
      sampler.onAccelerometer(0, 0, 39.0); // spike
      sampler.onAccelerometer(0, 0, 9.8);
      expect(sampler.tick(0).az, 39.0);
      expect(sampler.tick(20).az, 9.8); // back to the latest reading
    });
  });
}
