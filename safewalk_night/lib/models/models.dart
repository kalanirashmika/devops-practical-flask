import 'dart:math' as math;

/// A latitude/longitude fix (kept free of plugin types so logic is testable).
class GeoFix {
  final double lat, lng;
  final double? accuracy;
  final DateTime time;

  const GeoFix({required this.lat, required this.lng, this.accuracy, required this.time});

  String get mapsLink => 'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

  /// Great-circle distance in metres.
  static double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = p2 - p1, dl = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}

class TrustedContact {
  final String id, name, phone;
  const TrustedContact({required this.id, required this.name, required this.phone});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone};
  factory TrustedContact.fromJson(Map<String, dynamic> j) =>
      TrustedContact(id: j['id'] as String, name: j['name'] as String, phone: j['phone'] as String);
}

/// A community report of an unsafe place.
class UnsafeReport {
  static const List<String> categories = [
    'Poor lighting',
    'Isolated area',
    'Harassment reported',
    'Theft / robbery',
    'Stray dogs',
    'Other',
  ];

  final String id;
  final double lat, lng;
  final String category;
  final String note;
  final DateTime createdAt;

  /// How many people confirmed this report.
  final int confirmations;

  /// True for the built-in demonstration entries (not real reports).
  final bool sample;

  const UnsafeReport({
    required this.id,
    required this.lat,
    required this.lng,
    required this.category,
    this.note = '',
    required this.createdAt,
    this.confirmations = 1,
    this.sample = false,
  });

  UnsafeReport confirmed() => UnsafeReport(
        id: id,
        lat: lat,
        lng: lng,
        category: category,
        note: note,
        createdAt: createdAt,
        confirmations: confirmations + 1,
        sample: sample,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': lat,
        'lng': lng,
        'category': category,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'confirmations': confirmations,
        'sample': sample,
      };

  factory UnsafeReport.fromJson(Map<String, dynamic> j) => UnsafeReport(
        id: j['id'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        category: j['category'] as String,
        note: (j['note'] as String?) ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        confirmations: (j['confirmations'] as num?)?.toInt() ?? 1,
        sample: (j['sample'] as bool?) ?? false,
      );
}

/// One finished Safe Walk session (shown in History).
class WalkRecord {
  static const String completed = 'Completed safely';
  static const String alertCancelled = 'Alarm cancelled by user';
  static const String alertSent = 'Emergency alert sent';

  final String id;
  final DateTime startedAt, endedAt;
  final String outcome;
  final double peakConfidence;
  final int alarms;

  const WalkRecord({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.outcome,
    this.peakConfidence = 0,
    this.alarms = 0,
  });

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'outcome': outcome,
        'peakConfidence': peakConfidence,
        'alarms': alarms,
      };

  factory WalkRecord.fromJson(Map<String, dynamic> j) => WalkRecord(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        endedAt: DateTime.parse(j['endedAt'] as String),
        outcome: j['outcome'] as String,
        peakConfidence: (j['peakConfidence'] as num?)?.toDouble() ?? 0,
        alarms: (j['alarms'] as num?)?.toInt() ?? 0,
      );
}

class AppSettings {
  final String userName;

  /// 0 = low, 1 = medium, 2 = high.
  final int sensitivity;

  /// Seconds the user has to cancel before contacts are alerted.
  final int countdownSeconds;

  /// Seconds of no movement (after walking) treated as an abnormal stop.
  final int stopAlarmSeconds;

  const AppSettings({
    this.userName = '',
    this.sensitivity = 1,
    this.countdownSeconds = 15,
    this.stopAlarmSeconds = 90,
  });

  AppSettings copyWith({String? userName, int? sensitivity, int? countdownSeconds, int? stopAlarmSeconds}) =>
      AppSettings(
        userName: userName ?? this.userName,
        sensitivity: sensitivity ?? this.sensitivity,
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
        stopAlarmSeconds: stopAlarmSeconds ?? this.stopAlarmSeconds,
      );

  Map<String, dynamic> toJson() => {
        'userName': userName,
        'sensitivity': sensitivity,
        'countdownSeconds': countdownSeconds,
        'stopAlarmSeconds': stopAlarmSeconds,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        userName: (j['userName'] as String?) ?? '',
        sensitivity: ((j['sensitivity'] as num?)?.toInt() ?? 1).clamp(0, 2),
        countdownSeconds: ((j['countdownSeconds'] as num?)?.toInt() ?? 15).clamp(5, 60),
        stopAlarmSeconds: ((j['stopAlarmSeconds'] as num?)?.toInt() ?? 90).clamp(20, 600),
      );
}
