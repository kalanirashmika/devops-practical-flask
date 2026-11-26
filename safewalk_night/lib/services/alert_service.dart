import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';

/// Result of trying to alert one trusted contact.
class AlertDelivery {
  final TrustedContact contact;
  final bool sent;
  final String? error;
  const AlertDelivery(this.contact, this.sent, [this.error]);
}

/// Builds and delivers emergency messages.
class AlertService {
  static const MethodChannel _channel = MethodChannel('safewalk_night/sms');

  /// The emergency text sent to every trusted contact.
  static String buildAlertMessage({
    required String userName,
    required String reason,
    GeoFix? fix,
    DateTime? now,
  }) {
    final who = userName.trim().isEmpty ? 'Your contact' : userName.trim();
    final t = now ?? DateTime.now();
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final where = fix == null ? 'Location unavailable.' : 'Last location: ${fix.mapsLink}';
    return 'SAFEWALK ALERT: $who may need help ($reason, $time). $where';
  }

  static String buildLocationUpdate({required String userName, required GeoFix fix}) {
    final who = userName.trim().isEmpty ? 'Your contact' : userName.trim();
    return 'SafeWalk update: $who is now at ${fix.mapsLink}';
  }

  static String buildSafeMessage(String userName) {
    final who = userName.trim().isEmpty ? 'Your contact' : userName.trim();
    return 'SafeWalk: $who has confirmed they are safe. No further action needed.';
  }

  Future<bool> hasSmsPermission({bool request = false}) async {
    try {
      final status = request ? await Permission.sms.request() : await Permission.sms.status;
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Sends [message] to every contact automatically (no user interaction),
  /// using the phone's own SMS service through a small native channel.
  Future<List<AlertDelivery>> sendToAll(List<TrustedContact> contacts, String message) async {
    final results = <AlertDelivery>[];
    final allowed = await hasSmsPermission();
    for (final c in contacts) {
      if (!allowed) {
        results.add(AlertDelivery(c, false, 'SMS permission not granted'));
        continue;
      }
      try {
        await _channel.invokeMethod<void>('sendSms', {'phone': c.phone, 'message': message});
        results.add(AlertDelivery(c, true));
      } on PlatformException catch (e) {
        results.add(AlertDelivery(c, false, e.message ?? e.code));
      } catch (e) {
        results.add(AlertDelivery(c, false, '$e'));
      }
    }
    return results;
  }

  /// Fallback: opens the phone's SMS app with the message ready to send.
  Future<bool> openSmsApp(List<TrustedContact> contacts, String message) async {
    if (contacts.isEmpty) return false;
    final uri = Uri(
      scheme: 'sms',
      path: contacts.map((c) => c.phone).join(','),
      queryParameters: {'body': message},
    );
    try {
      return await launchUrl(uri);
    } catch (_) {
      return false;
    }
  }
}
