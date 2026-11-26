import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../services/session_controller.dart';

/// Full-screen alarm: countdown with cancel, then the "alert sent" summary.
class AlertScreen extends StatelessWidget {
  const AlertScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: c.phase == SessionPhase.countdown ? const Color(0xFF8C1D22) : const Color(0xFF1B1F3A),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: c.phase == SessionPhase.countdown ? _Countdown(c: c) : _Sent(c: c),
          ),
        ),
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  final SessionController c;
  const _Countdown({required this.c});

  @override
  Widget build(BuildContext context) {
    final progress = c.countdownTotal == 0 ? 0.0 : c.countdownRemaining / c.countdownTotal;
    return Column(
      children: [
        const SizedBox(height: 12),
        const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 56),
        const SizedBox(height: 8),
        const Text('Are you OK?', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'Reason: ${c.alertReason}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
        const Spacer(),
        SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: progress,
                strokeWidth: 10,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
              Center(
                child: Text(
                  '${c.countdownRemaining}',
                  key: const Key('countdown-number'),
                  style: const TextStyle(color: Colors.white, fontSize: 84, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Your trusted contacts will be alerted with your\nlocation when the countdown ends.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('cancel-alarm'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF8C1D22),
              padding: const EdgeInsets.symmetric(vertical: 22),
            ),
            onPressed: c.cancelCountdown,
            child: const Text("I'M OK - CANCEL", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: c.sendAlertNow,
          child: const Text('Send alert now', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _Sent extends StatelessWidget {
  final SessionController c;
  const _Sent({required this.c});

  @override
  Widget build(BuildContext context) {
    final fix = c.lastFix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Center(child: Icon(Icons.notifications_active, color: Colors.amber, size: 56)),
        const SizedBox(height: 8),
        const Center(
          child: Text('Emergency alert', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 6),
        Center(child: Text('Reason: ${c.alertReason}', textAlign: TextAlign.center)),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.statusNote, key: const Key('alert-status'), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                for (final d in c.deliveries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(d.sent ? Icons.check_circle : Icons.error_outline, color: d.sent ? Colors.green : Colors.amber),
                    title: Text('${d.contact.name} (${d.contact.phone})'),
                    subtitle: d.sent ? const Text('SMS sent') : Text(d.error ?? 'Not sent'),
                  ),
                const Divider(),
                Text(
                  fix == null
                      ? 'Location: not available'
                      : 'Location shared: ${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}',
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        if (c.smsFailed && c.deliveries.isNotEmpty)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: c.openSmsFallback,
              icon: const Icon(Icons.sms_outlined),
              label: const Text('Open SMS app with the alert'),
            ),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('mark-safe'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2FBF71),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
            onPressed: c.markSafe,
            child: const Text("I'M SAFE NOW", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}
