import 'package:flutter_test/flutter_test.dart';
import 'package:safewalk_night/models/models.dart';
import 'package:safewalk_night/services/alert_service.dart';
import 'package:safewalk_night/services/app_store.dart';
import 'package:safewalk_night/services/route_service.dart';

void main() {
  final t = DateTime(2026, 11, 27, 23, 5);

  group('alert message', () {
    test('contains who, why, when and a map link to the live location', () {
      final msg = AlertService.buildAlertMessage(
        userName: 'Chinthaka',
        reason: 'possible fall detected, 87% confidence',
        fix: GeoFix(lat: 6.8213, lng: 80.0416, time: t),
        now: t,
      );
      expect(msg, contains('SAFEWALK ALERT'));
      expect(msg, contains('Chinthaka'));
      expect(msg, contains('possible fall detected'));
      expect(msg, contains('23:05'));
      expect(msg, contains('https://maps.google.com/?q=6.821300,80.041600'));
    });

    test('still works without a name or a location', () {
      final msg = AlertService.buildAlertMessage(userName: ' ', reason: 'manual SOS', now: t);
      expect(msg, contains('Your contact may need help'));
      expect(msg, contains('Location unavailable'));
    });
  });

  group('app store', () {
    test('contacts, reports, history and settings survive a restart', () async {
      final backend = MemoryBackend();
      final a = AppStore(backend);
      await a.load();
      expect(a.reports.every((r) => r.sample), isTrue, reason: 'first run shows labelled sample reports');

      await a.addContact('  Amma ', '077 123-4567');
      await a.addReport(lat: 6.82, lng: 80.04, category: 'Poor lighting', note: 'dark corner');
      await a.updateSettings(a.settings.copyWith(userName: 'Chinthaka', sensitivity: 2, countdownSeconds: 10));
      await a.addRecord(WalkRecord(id: '1', startedAt: t, endedAt: t.add(const Duration(minutes: 9)), outcome: WalkRecord.completed));

      final b = AppStore(backend);
      await b.load();
      expect(b.contacts.single.name, 'Amma');
      expect(b.contacts.single.phone, '0771234567');
      expect(b.reports.where((r) => !r.sample).single.note, 'dark corner');
      expect(b.settings.sensitivity, 2);
      expect(b.settings.countdownSeconds, 10);
      expect(b.history.single.duration.inMinutes, 9);
    });

    test('phone validation', () {
      expect(AppStore.isValidPhone('0771234567'), isTrue);
      expect(AppStore.isValidPhone('+94 77 123 4567'), isTrue);
      expect(AppStore.normalisePhone('+94 77 123 4567'), '+94771234567');
      expect(AppStore.isValidPhone('12345'), isFalse);
      expect(AppStore.isValidPhone('abc'), isFalse);
    });

    test('confirming a report raises its count', () async {
      final store = AppStore(MemoryBackend());
      await store.load();
      final first = store.reports.first;
      await store.confirmReport(first.id);
      expect(store.reports.first.confirmations, first.confirmations + 1);
    });
  });

  group('safer route suggestion', () {
    // Two routes between the same points: a short one that passes a reported
    // spot and a slightly longer one that stays away from it.
    final shortThroughDanger = RouteOption(
      points: [
        [6.8200, 80.0400],
        [6.8210, 80.0410],
        [6.8220, 80.0420],
      ],
      distanceMeters: 320,
      durationSeconds: 240,
    );
    final longerButClear = RouteOption(
      points: [
        [6.8200, 80.0400],
        [6.8200, 80.0440],
        [6.8220, 80.0440],
        [6.8220, 80.0420],
      ],
      distanceMeters: 880,
      durationSeconds: 660,
    );
    final report = UnsafeReport(id: 'r', lat: 6.8210, lng: 80.0410, category: 'Poor lighting', createdAt: t, confirmations: 3);

    test('prefers the route that avoids reported unsafe spots', () {
      final ranked = RouteService.rankBySafety([shortThroughDanger, longerButClear], [report]);
      expect(ranked.first.distanceMeters, 880);
      expect(ranked.first.reportsNearby, 0);
      expect(ranked.last.reportsNearby, 1);
      expect(ranked.last.risk, greaterThan(0));
    });

    test('with no reports nearby the shortest route wins', () {
      final ranked = RouteService.rankBySafety([longerButClear, shortThroughDanger], const []);
      expect(ranked.first.distanceMeters, 320);
    });

    test('a report confirmed by more people weighs more', () {
      final many = UnsafeReport(id: 'm', lat: 6.8210, lng: 80.0410, category: 'Theft / robbery', createdAt: t, confirmations: 6);
      final a = RouteService.rankBySafety([shortThroughDanger], [report]).single.risk;
      final b = RouteService.rankBySafety([shortThroughDanger], [many]).single.risk;
      expect(b, greaterThan(a));
    });

    test('parses a routing-service response', () {
      const body = '{"code":"Ok","routes":[{"distance":1234.5,"duration":900,'
          '"geometry":{"coordinates":[[80.04,6.82],[80.05,6.83]],"type":"LineString"}}]}';
      final routes = RouteService.parseOsrm(body);
      expect(routes.single.distanceMeters, 1234.5);
      expect(routes.single.points.first, [6.82, 80.04]); // lat, lng order
    });

    test('detour points sit either side of the direct line', () {
      final from = GeoFix(lat: 6.82, lng: 80.04, time: t), to = GeoFix(lat: 6.83, lng: 80.04, time: t);
      final via = RouteService.viaPoints(from, to);
      expect(via.length, 2);
      expect(via[0].lat, closeTo(6.825, 1e-6));
      expect(via[0].lng < 80.04 != via[1].lng < 80.04, isTrue);
      final offset = GeoFix.distanceMeters(6.825, 80.04, via[0].lat, via[0].lng);
      expect(offset, closeTo(0.3 * GeoFix.distanceMeters(6.82, 80.04, 6.83, 80.04), 5));
    });

    test('distance helper is accurate', () {
      // One degree of latitude is about 111.2 km.
      expect(GeoFix.distanceMeters(6, 80, 7, 80), closeTo(111195, 200));
    });
  });
}
