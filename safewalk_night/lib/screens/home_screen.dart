import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../detection/detection_engine.dart';
import '../services/app_store.dart';
import '../services/session_controller.dart';

String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

class HomeScreen extends StatelessWidget {
  final VoidCallback onOpenContacts;
  const HomeScreen({super.key, required this.onOpenContacts});

  Future<void> _toggle(BuildContext context, SessionController c) async {
    final messenger = ScaffoldMessenger.of(context);
    if (c.sessionRunning) {
      await c.stop();
      messenger.showSnackBar(const SnackBar(content: Text('Safe Walk ended and saved to history.')));
      return;
    }
    final error = await c.start();
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _shareLocation(BuildContext context, SessionController c) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = context.read<AppStore>().settings.userName.trim();
    final fix = c.lastFix ?? await c.location.current();
    if (fix == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Location is not available yet. Check GPS and permission.')));
      return;
    }
    c.lastFix = fix;
    final who = name.isEmpty ? 'I am' : '$name is';
    await SharePlus.instance.share(ShareParams(text: '$who sharing a live location via SafeWalk Night: ${fix.mapsLink}'));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SessionController>();
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final running = c.sessionRunning;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Row(
          children: [
            Icon(Icons.shield_moon, color: scheme.primary, size: 30),
            const SizedBox(width: 10),
            Text('SafeWalk Night', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          running ? 'Your walk is being monitored.' : 'Start a Safe Walk before you set off alone.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        if (store.loaded && store.contacts.isEmpty)
          Card(
            color: const Color(0xFF3A2A12),
            child: ListTile(
              leading: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
              title: const Text('No trusted contacts yet'),
              subtitle: const Text('Add at least one so someone can be alerted in an emergency.'),
              trailing: TextButton(onPressed: onOpenContacts, child: const Text('Add')),
            ),
          ),
        const SizedBox(height: 20),
        Center(
          child: _SessionButton(
            running: running,
            busy: c.starting,
            onTap: () => _toggle(context, c),
          ),
        ),
        const SizedBox(height: 20),
        if (running) ...[
          _StatusCard(controller: c),
          const SizedBox(height: 12),
          _DetectionCard(snapshot: c.snapshot, triggerLevel: EngineConfig.forSensitivity(store.settings.sensitivity).triggerLevel),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('sos-button'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE5484D),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                onPressed: c.triggerSos,
                icon: const Icon(Icons.sos),
                label: const Text('SOS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
                onPressed: () => _shareLocation(context, c),
                icon: const Icon(Icons.share_location),
                label: const Text('Share location'),
              ),
            ),
          ],
        ),
        if (running) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: c.simulating ? null : c.simulateFall,
              icon: const Icon(Icons.science_outlined, size: 18),
              label: Text(c.simulating ? 'Simulating a fall...' : 'Simulate a fall (demo)'),
            ),
          ),
        ],
      ],
    );
  }
}

class _SessionButton extends StatelessWidget {
  final bool running, busy;
  final VoidCallback onTap;
  const _SessionButton({required this.running, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = running ? const Color(0xFF2FBF71) : Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      label: running ? 'Stop Safe Walk' : 'Start Safe Walk',
      child: InkWell(
        key: const Key('session-button'),
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: Container(
          width: 190,
          height: 190,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.14),
            border: Border.all(color: color, width: 4),
          ),
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(running ? Icons.stop_rounded : Icons.directions_walk, size: 54, color: color),
                    const SizedBox(height: 6),
                    Text(
                      running ? 'STOP' : 'START',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color, letterSpacing: 1.5),
                    ),
                    Text('Safe Walk', style: TextStyle(color: color)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final SessionController controller;
  const _StatusCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final snap = c.snapshot;
    final elapsed = DateTime.now().difference(c.startedAt ?? DateTime.now());
    final String movement;
    if (!c.sensorsAvailable) {
      movement = 'Motion sensors unavailable';
    } else if (snap == null) {
      movement = 'Collecting motion data...';
    } else if (snap.walking) {
      movement = 'Walking';
    } else if (snap.atRest) {
      movement = snap.stillSeconds > 0 ? 'Still for ${snap.stillSeconds.round()} s' : 'Still';
    } else {
      movement = 'Moving';
    }
    final fix = c.lastFix;
    final where = fix != null
        ? '${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}'
        : (c.locationAvailable ? 'Waiting for GPS...' : 'Location off / not permitted');

    Widget row(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const Spacer(),
              Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            row(Icons.timer_outlined, 'Session time', formatDuration(elapsed)),
            row(Icons.directions_walk, 'Movement', movement),
            row(Icons.place_outlined, 'Location', where),
            row(Icons.memory, 'ML engine', c.modelBackend.isEmpty ? '-' : c.modelBackend),
            if (snap != null) row(Icons.person_outline, 'Personal baseline', '${snap.baselineWindows} samples learned'),
          ],
        ),
      ),
    );
  }
}

class _DetectionCard extends StatelessWidget {
  final EngineSnapshot? snapshot;
  final double triggerLevel;
  const _DetectionCard({required this.snapshot, required this.triggerLevel});

  @override
  Widget build(BuildContext context) {
    final f = snapshot?.fusion;
    final scheme = Theme.of(context).colorScheme;

    Widget bar(String label, double value, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400))),
                  Text('${(value * 100).round()}%', style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  minHeight: bold ? 10 : 7,
                  color: color ?? scheme.primary,
                  backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
                ),
              ),
            ],
          ),
        );

    final combined = f?.confidence ?? 0;
    final combinedColor = combined >= triggerLevel
        ? const Color(0xFFE5484D)
        : (combined >= triggerLevel * 0.6 ? Colors.amber : const Color(0xFF2FBF71));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Anomaly detection', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            Text(
              'Three methods, combined by a weighted confidence check',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 8),
            bar('1. Threshold rules', f?.fall.threshold ?? 0),
            bar('2. Statistical (jerk / SMA)', f?.fall.statistical ?? 0),
            bar('3. ML classifier', f?.fall.ml ?? 0),
            bar('Prolonged-stop check', f?.stopConfidence ?? 0, color: scheme.tertiary),
            const Divider(height: 22),
            bar('Combined confidence', combined, color: combinedColor, bold: true),
            Text(
              'Alarm at ${(triggerLevel * 100).round()}% with at least two methods agreeing',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
