import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../detection/detection_engine.dart';
import '../detection/fall_model.dart';
import '../detection/fusion.dart';
import '../detection/motion_sampler.dart';
import '../detection/sensor_sample.dart';
import '../detection/synthetic_motion.dart';
import '../models/models.dart';
import 'alert_service.dart';
import 'app_store.dart';
import 'location_service.dart';

enum SessionPhase {
  /// No Safe Walk session running.
  idle,

  /// Session running, motion being analysed.
  active,

  /// An anomaly (or SOS) was raised; the user can still cancel.
  countdown,

  /// Trusted contacts have been alerted.
  alertSent,
}

/// Runs a Safe Walk session: sensors -> detection engine -> countdown ->
/// emergency alert. The UI only listens to this object.
class SessionController extends ChangeNotifier {
  final AppStore store;
  final LocationService location;
  final AlertService alerts;
  final Future<FallModel> Function() modelLoader;

  SessionController({
    required this.store,
    required this.modelLoader,
    LocationService? location,
    AlertService? alerts,
  })  : location = location ?? LocationService(),
        alerts = alerts ?? AlertService();

  static const int sosCountdownSeconds = 5;
  static const Duration followUpEvery = Duration(minutes: 2);
  static const int maxFollowUps = 5;

  SessionPhase phase = SessionPhase.idle;
  EngineSnapshot? snapshot;
  GeoFix? lastFix;
  DateTime? startedAt;
  int countdownRemaining = 0;
  int countdownTotal = 0;
  String alertReason = '';
  String statusNote = '';
  List<AlertDelivery> deliveries = const [];
  String modelBackend = '';
  bool simulating = false;
  bool sensorsAvailable = true;
  bool locationAvailable = false;
  bool starting = false;

  bool get sessionRunning => _sessionRunning;
  bool get smsFailed => deliveries.isEmpty || deliveries.every((d) => !d.sent);

  FallModel? _model;
  DetectionEngine? _engine;
  final MotionSampler _sampler = MotionSampler();
  final Queue<SensorSample> _simQueue = Queue<SensorSample>();
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<GeoFix>? _locSub;
  Timer? _sampleTimer, _countdownTimer, _followUpTimer;
  bool _sessionRunning = false;
  double _peak = 0;
  int _alarms = 0;
  int _followUps = 0;
  int _ticks = 0;
  String _outcome = WalkRecord.completed;
  DateTime? _sosStartedAt;

  EngineConfig get _config => EngineConfig.forSensitivity(
        store.settings.sensitivity,
        stopAlarmSeconds: store.settings.stopAlarmSeconds.toDouble(),
      );

  /// Starts a Safe Walk session. Returns an error message, or null on success.
  Future<String?> start() async {
    if (phase != SessionPhase.idle || starting) return null;
    starting = true;
    notifyListeners();
    try {
      _model ??= await modelLoader();
      modelBackend = _model!.backend;
      _engine = DetectionEngine(model: _model!, config: _config);

      locationAvailable = await location.ensurePermission();
      try {
        await Permission.notification.request();
      } catch (_) {}
      await alerts.hasSmsPermission(request: true);

      sensorsAvailable = true;
      _accSub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (e) => _sampler.onAccelerometer(e.x, e.y, e.z),
        onError: (_) {
          sensorsAvailable = false;
          notifyListeners();
        },
        cancelOnError: true,
      );
      _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        (e) => _sampler.onGyroscope(e.x, e.y, e.z),
        onError: (_) {},
        cancelOnError: true,
      );
      _sampleTimer = Timer.periodic(const Duration(milliseconds: 20), (_) => _onTick());

      if (locationAvailable) {
        _locSub = location.watchSession().listen((fix) {
          lastFix = fix;
        }, onError: (_) {});
      }

      _sessionRunning = true;
      _peak = 0;
      _alarms = 0;
      _outcome = WalkRecord.completed;
      snapshot = null;
      startedAt = DateTime.now();
      phase = SessionPhase.active;
      return null;
    } catch (e) {
      await _releaseSensors();
      return 'Could not start the session: $e';
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  void _onTick() {
    // Keep the on-screen session timer moving even if no sensor data arrives.
    if (++_ticks % 50 == 0 && phase == SessionPhase.active) notifyListeners();
    SensorSample? sample;
    if (_simQueue.isNotEmpty) {
      sample = _simQueue.removeFirst();
      _sampler.tick(0); // discard the real reading for this tick
      if (_simQueue.isEmpty) simulating = false;
    } else if (_sampler.hasData) {
      sample = _sampler.tick(DateTime.now().millisecondsSinceEpoch);
    }
    if (sample == null || phase != SessionPhase.active) return;
    acceptSample(sample);
  }

  /// Feeds one fixed-rate sample to the engine (public for tests).
  @visibleForTesting
  void acceptSample(SensorSample sample) {
    final snap = _engine?.addSample(sample);
    if (snap == null) return;
    snapshot = snap;
    if (snap.fusion.confidence > _peak) _peak = snap.fusion.confidence;
    if (snap.fusion.triggered) {
      final pct = (snap.fusion.confidence * 100).round();
      final reason = snap.fusion.type == AnomalyType.fall
          ? 'possible fall detected, $pct% confidence'
          : 'no movement for ${snap.stillSeconds.round()} s after walking';
      _beginCountdown(reason, store.settings.countdownSeconds);
    } else {
      notifyListeners();
    }
  }

  /// Replays a simulated walk + fall through the real detection pipeline.
  void simulateFall() {
    if (phase != SessionPhase.active) return;
    final m = SyntheticMotion(DateTime.now().millisecond + 1);
    _engine?.resume(cooldownSeconds: 0);
    _simQueue
      ..clear()
      ..addAll(m.walking(5))
      ..addAll(m.fall(stillSeconds: 5));
    simulating = true;
    notifyListeners();
  }

  /// Manual SOS - works with or without a running session.
  void triggerSos() {
    if (phase == SessionPhase.countdown || phase == SessionPhase.alertSent) return;
    if (!_sessionRunning) _sosStartedAt = DateTime.now();
    _beginCountdown('manual SOS', sosCountdownSeconds);
  }

  void _beginCountdown(String reason, int seconds) {
    _countdownTimer?.cancel();
    alertReason = reason;
    countdownTotal = seconds;
    countdownRemaining = seconds;
    deliveries = const [];
    statusNote = '';
    _alarms++;
    phase = SessionPhase.countdown;
    HapticFeedback.heavyImpact();
    notifyListeners();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      countdownRemaining--;
      HapticFeedback.heavyImpact();
      if (countdownRemaining <= 0) {
        t.cancel();
        sendAlertNow();
      } else {
        notifyListeners();
      }
    });
  }

  /// "I'm OK" - the alarm was false.
  void cancelCountdown() {
    if (phase != SessionPhase.countdown) return;
    _countdownTimer?.cancel();
    if (_outcome != WalkRecord.alertSent) _outcome = WalkRecord.alertCancelled;
    _backToNormal();
  }

  /// Alerts every trusted contact with the latest known location.
  Future<void> sendAlertNow() async {
    if (phase != SessionPhase.countdown) return;
    _countdownTimer?.cancel();
    phase = SessionPhase.alertSent;
    statusNote = 'Sending alert...';
    _outcome = WalkRecord.alertSent;
    notifyListeners();

    lastFix ??= await location.current();
    final contacts = store.contacts;
    final message = AlertService.buildAlertMessage(
      userName: store.settings.userName,
      reason: alertReason,
      fix: lastFix,
    );
    if (contacts.isEmpty) {
      statusNote = 'No trusted contacts are saved, so nobody could be alerted.';
    } else {
      deliveries = await alerts.sendToAll(contacts, message);
      final sent = deliveries.where((d) => d.sent).length;
      if (sent > 0) {
        statusNote = 'Alert sent by SMS to $sent of ${contacts.length} contact(s).';
        _startFollowUps();
      } else {
        final opened = await alerts.openSmsApp(contacts, message);
        statusNote = opened
            ? 'Automatic SMS was not possible - your SMS app was opened with the alert ready to send.'
            : 'The alert could not be sent automatically (${deliveries.first.error ?? 'unknown error'}).';
      }
    }
    if (phase == SessionPhase.alertSent) notifyListeners();
  }

  void _startFollowUps() {
    _followUpTimer?.cancel();
    _followUps = 0;
    GeoFix? lastSent = lastFix;
    _followUpTimer = Timer.periodic(followUpEvery, (t) async {
      final fix = lastFix;
      if (_followUps >= maxFollowUps || phase != SessionPhase.alertSent) {
        t.cancel();
        return;
      }
      if (fix == null || identical(fix, lastSent)) return;
      lastSent = fix;
      _followUps++;
      await alerts.sendToAll(
        store.contacts,
        AlertService.buildLocationUpdate(userName: store.settings.userName, fix: fix),
      );
    });
  }

  /// The user confirms they are safe after an alert went out.
  Future<void> markSafe() async {
    if (phase != SessionPhase.alertSent) return;
    _followUpTimer?.cancel();
    final anySent = deliveries.any((d) => d.sent);
    _backToNormal();
    if (anySent) {
      await alerts.sendToAll(store.contacts, AlertService.buildSafeMessage(store.settings.userName));
    }
  }

  /// Opens the SMS app with the alert text (manual fallback from the UI).
  Future<bool> openSmsFallback() => alerts.openSmsApp(
        store.contacts,
        AlertService.buildAlertMessage(userName: store.settings.userName, reason: alertReason, fix: lastFix),
      );

  void _backToNormal() {
    if (_sessionRunning) {
      _engine?.resume();
      _simQueue.clear();
      simulating = false;
      phase = SessionPhase.active;
    } else {
      phase = SessionPhase.idle;
      final began = _sosStartedAt;
      if (began != null) {
        store.addRecord(WalkRecord(
          id: began.microsecondsSinceEpoch.toString(),
          startedAt: began,
          endedAt: DateTime.now(),
          outcome: _outcome == WalkRecord.alertSent ? 'SOS - ${WalkRecord.alertSent}' : 'SOS cancelled',
          alarms: 1,
        ));
        _sosStartedAt = null;
        _outcome = WalkRecord.completed;
      }
    }
    notifyListeners();
  }

  /// Ends the session and saves it to the history.
  Future<void> stop() async {
    if (!_sessionRunning) return;
    _countdownTimer?.cancel();
    _followUpTimer?.cancel();
    await _releaseSensors();
    _sessionRunning = false;
    final began = startedAt ?? DateTime.now();
    phase = SessionPhase.idle;
    snapshot = null;
    simulating = false;
    _simQueue.clear();
    notifyListeners();
    await store.addRecord(WalkRecord(
      id: began.microsecondsSinceEpoch.toString(),
      startedAt: began,
      endedAt: DateTime.now(),
      outcome: _outcome,
      peakConfidence: _peak,
      alarms: _alarms,
    ));
  }

  Future<void> _releaseSensors() async {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    await _accSub?.cancel();
    await _gyroSub?.cancel();
    await _locSub?.cancel();
    _accSub = null;
    _gyroSub = null;
    _locSub = null;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _followUpTimer?.cancel();
    _releaseSensors();
    super.dispose();
  }
}
