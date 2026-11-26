import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// Where the app's data is persisted.
///
/// The prototype stores everything on the phone ([PrefsBackend]). A Cloud
/// Firestore implementation of this same interface can be dropped in later
/// to make contacts and community reports sync between users.
abstract class StorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PrefsBackend implements StorageBackend {
  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
}

class MemoryBackend implements StorageBackend {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// App-wide state: trusted contacts, unsafe-location reports, walk history
/// and settings.
class AppStore extends ChangeNotifier {
  final StorageBackend backend;
  AppStore(this.backend);

  List<TrustedContact> contacts = [];
  List<UnsafeReport> reports = [];
  List<WalkRecord> history = [];
  AppSettings settings = const AppSettings();
  bool loaded = false;

  static const _kContacts = 'contacts', _kReports = 'reports', _kHistory = 'history', _kSettings = 'settings';

  Future<void> load() async {
    List<T> list<T>(String? raw, T Function(Map<String, dynamic>) parse) {
      if (raw == null) return [];
      try {
        return [for (final e in jsonDecode(raw) as List) parse(e as Map<String, dynamic>)];
      } catch (_) {
        return [];
      }
    }

    contacts = list(await backend.read(_kContacts), TrustedContact.fromJson);
    history = list(await backend.read(_kHistory), WalkRecord.fromJson);
    final rawReports = await backend.read(_kReports);
    reports = rawReports == null ? sampleReports() : list(rawReports, UnsafeReport.fromJson);
    final rawSettings = await backend.read(_kSettings);
    if (rawSettings != null) {
      try {
        settings = AppSettings.fromJson(jsonDecode(rawSettings) as Map<String, dynamic>);
      } catch (_) {}
    }
    loaded = true;
    notifyListeners();
  }

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _save(String key, List<Map<String, dynamic>> items) => backend.write(key, jsonEncode(items));

  Future<void> addContact(String name, String phone) async {
    contacts = [...contacts, TrustedContact(id: _newId(), name: name.trim(), phone: normalisePhone(phone))];
    notifyListeners();
    await _save(_kContacts, [for (final c in contacts) c.toJson()]);
  }

  Future<void> removeContact(String id) async {
    contacts = contacts.where((c) => c.id != id).toList();
    notifyListeners();
    await _save(_kContacts, [for (final c in contacts) c.toJson()]);
  }

  Future<void> addReport({required double lat, required double lng, required String category, String note = ''}) async {
    reports = [
      ...reports,
      UnsafeReport(id: _newId(), lat: lat, lng: lng, category: category, note: note.trim(), createdAt: DateTime.now()),
    ];
    notifyListeners();
    await _save(_kReports, [for (final r in reports) r.toJson()]);
  }

  Future<void> confirmReport(String id) async {
    reports = [for (final r in reports) r.id == id ? r.confirmed() : r];
    notifyListeners();
    await _save(_kReports, [for (final r in reports) r.toJson()]);
  }

  Future<void> removeReport(String id) async {
    reports = reports.where((r) => r.id != id).toList();
    notifyListeners();
    await _save(_kReports, [for (final r in reports) r.toJson()]);
  }

  Future<void> addRecord(WalkRecord record) async {
    history = [record, ...history].take(100).toList();
    notifyListeners();
    await _save(_kHistory, [for (final r in history) r.toJson()]);
  }

  Future<void> clearHistory() async {
    history = [];
    notifyListeners();
    await _save(_kHistory, []);
  }

  Future<void> updateSettings(AppSettings value) async {
    settings = value;
    notifyListeners();
    await backend.write(_kSettings, jsonEncode(value.toJson()));
  }

  /// Keeps digits and a leading +, e.g. "077 123-4567" -> "0771234567".
  static String normalisePhone(String input) {
    final t = input.trim();
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    return t.startsWith('+') ? '+$digits' : digits;
  }

  static bool isValidPhone(String input) {
    final digits = normalisePhone(input).replaceAll('+', '');
    return digits.length >= 9 && digits.length <= 15;
  }

  /// Demonstration entries around NSBM Green University (Pitipana, Homagama)
  /// so the map and safer-route feature can be shown before anyone has
  /// reported anything. They are clearly labelled as samples in the app.
  static List<UnsafeReport> sampleReports() {
    final t = DateTime(2026, 11, 1);
    UnsafeReport s(String id, double lat, double lng, String cat, String note, int n) => UnsafeReport(
        id: id, lat: lat, lng: lng, category: cat, note: note, createdAt: t, confirmations: n, sample: true);
    return [
      s('sample-1', 6.8235, 80.0398, 'Poor lighting', 'Street lamps not working on this stretch', 4),
      s('sample-2', 6.8189, 80.0437, 'Isolated area', 'No houses or shops, very quiet after 9pm', 3),
      s('sample-3', 6.8262, 80.0451, 'Stray dogs', 'Pack of dogs near the junction at night', 2),
      s('sample-4', 6.8158, 80.0389, 'Harassment reported', 'Reported near the bus halt', 5),
    ];
  }
}
