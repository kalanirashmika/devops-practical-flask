import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:safewalk_night/detection/fall_model.dart';
import 'package:safewalk_night/main.dart';
import 'package:safewalk_night/models/models.dart';
import 'package:safewalk_night/services/alert_service.dart';
import 'package:safewalk_night/services/app_store.dart';
import 'package:safewalk_night/services/location_service.dart';
import 'package:safewalk_night/services/session_controller.dart';

class FakeLocation extends LocationService {
  GeoFix? fix = GeoFix(lat: 6.8213, lng: 80.0416, time: DateTime(2026, 11, 27, 23));

  @override
  Future<bool> ensurePermission() async => fix != null;

  @override
  Future<GeoFix?> current() async => fix;
}

class FakeAlerts extends AlertService {
  final List<String> sent = [];
  bool smsAllowed = true;
  int smsAppOpened = 0;

  @override
  Future<bool> hasSmsPermission({bool request = false}) async => smsAllowed;

  @override
  Future<List<AlertDelivery>> sendToAll(List<TrustedContact> contacts, String message) async {
    if (smsAllowed) sent.add(message);
    return [for (final c in contacts) AlertDelivery(c, smsAllowed, smsAllowed ? null : 'SMS permission not granted')];
  }

  @override
  Future<bool> openSmsApp(List<TrustedContact> contacts, String message) async {
    smsAppOpened++;
    return true;
  }
}

Future<FallModel> testModel() async =>
    MlpFallModel.fromJson(File('assets/models/fall_model.json').readAsStringSync());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppStore store;
  late FakeAlerts alerts;
  late FakeLocation location;
  late SessionController c;

  Future<void> setUpWith({bool contact = true}) async {
    store = AppStore(MemoryBackend());
    await store.load();
    if (contact) await store.addContact('Amma', '0771234567');
    await store.updateSettings(store.settings.copyWith(userName: 'Chinthaka'));
    alerts = FakeAlerts();
    location = FakeLocation();
    c = SessionController(store: store, modelLoader: testModel, location: location, alerts: alerts);
  }

  test('SOS: countdown runs, then contacts get an SMS with the live location', () async {
    await setUpWith();
    fakeAsync((async) {
      c.triggerSos();
      expect(c.phase, SessionPhase.countdown);
      expect(c.countdownRemaining, SessionController.sosCountdownSeconds);

      async.elapse(const Duration(seconds: 3));
      expect(c.countdownRemaining, 2);
      expect(alerts.sent, isEmpty, reason: 'nothing is sent while the user can still cancel');

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(c.phase, SessionPhase.alertSent);
      expect(alerts.sent.single, contains('Chinthaka'));
      expect(alerts.sent.single, contains('manual SOS'));
      expect(alerts.sent.single, contains('https://maps.google.com/?q=6.821300,80.041600'));
      expect(c.statusNote, contains('1 of 1'));

      c.markSafe();
      async.flushMicrotasks();
      expect(c.phase, SessionPhase.idle);
      expect(alerts.sent.last, contains('confirmed they are safe'));
      expect(store.history.single.outcome, contains(WalkRecord.alertSent));
    });
  });

  test('cancelling inside the countdown sends nothing', () async {
    await setUpWith();
    fakeAsync((async) {
      c.triggerSos();
      async.elapse(const Duration(seconds: 4));
      c.cancelCountdown();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(c.phase, SessionPhase.idle);
      expect(alerts.sent, isEmpty);
      expect(store.history.single.outcome, 'SOS cancelled');
    });
  });

  test('"send now" skips the rest of the countdown', () async {
    await setUpWith();
    c.triggerSos();
    await c.sendAlertNow();
    expect(c.phase, SessionPhase.alertSent);
    expect(alerts.sent.length, 1);
    c.dispose();
  });

  test('without SMS permission it falls back to opening the SMS app', () async {
    await setUpWith();
    alerts.smsAllowed = false;
    c.triggerSos();
    await c.sendAlertNow();
    expect(alerts.sent, isEmpty);
    expect(alerts.smsAppOpened, 1);
    expect(c.smsFailed, isTrue);
    expect(c.statusNote, contains('SMS app was opened'));
    c.dispose();
  });

  test('with no trusted contacts the user is told nobody was alerted', () async {
    await setUpWith(contact: false);
    c.triggerSos();
    await c.sendAlertNow();
    expect(alerts.sent, isEmpty);
    expect(c.statusNote, contains('No trusted contacts'));
    c.dispose();
  });

  test('an alert still goes out when the location is unavailable', () async {
    await setUpWith();
    location.fix = null;
    c.triggerSos();
    await c.sendAlertNow();
    expect(alerts.sent.single, contains('Location unavailable'));
    c.dispose();
  });

  testWidgets('home screen shows Start, SOS and the no-contacts warning; SOS opens the countdown', (tester) async {
    final store = AppStore(MemoryBackend());
    await store.load();
    await tester.pumpWidget(SafeWalkApp(store: store, modelLoader: testModel));
    await tester.pump();

    expect(find.text('SafeWalk Night'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('No trusted contacts yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pump();
    expect(find.text('Are you OK?'), findsOneWidget);
    expect(find.byKey(const Key('countdown-number')), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-alarm')));
    await tester.pump();
    expect(find.text('START'), findsOneWidget);
    expect(find.text('Are you OK?'), findsNothing);
  });
}
