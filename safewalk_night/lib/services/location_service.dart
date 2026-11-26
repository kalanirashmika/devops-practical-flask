import 'package:geolocator/geolocator.dart';

import '../models/models.dart';

/// Thin wrapper around the geolocator plugin.
class LocationService {
  GeoFix _fix(Position p) => GeoFix(lat: p.latitude, lng: p.longitude, accuracy: p.accuracy, time: p.timestamp);

  /// Asks for location permission if needed. Returns false when unavailable.
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return permission == LocationPermission.always || permission == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  Future<GeoFix?> current() async {
    try {
      if (!await ensurePermission()) return null;
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
      );
      return _fix(p);
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        return last == null ? null : _fix(last);
      } catch (_) {
        return null;
      }
    }
  }

  /// Continuous location updates for an active Safe Walk session.
  ///
  /// On Android this runs as a foreground service with a persistent
  /// notification and a wake lock, which is what keeps the session (and the
  /// motion sensors) alive while the phone is locked in a pocket.
  Stream<GeoFix> watchSession() {
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'SafeWalk Night is watching over your walk',
        notificationText: 'Motion monitoring and live location are active.',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    return Geolocator.getPositionStream(locationSettings: settings).map(_fix);
  }
}
