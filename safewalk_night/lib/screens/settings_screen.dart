import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../detection/detection_engine.dart';
import '../detection/fusion.dart';
import '../services/app_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.read<AppStore>().settings.userName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final s = store.settings;
    final scheme = Theme.of(context).colorScheme;
    final level = EngineConfig.forSensitivity(s.sensitivity).triggerLevel;

    Widget section(String title, List<Widget> children) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 8),
                ...children,
              ],
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          section('Your name', [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Shown in the alert message'),
              onChanged: (v) => store.updateSettings(s.copyWith(userName: v)),
            ),
          ]),
          const SizedBox(height: 12),
          section('Detection sensitivity', [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Low')),
                ButtonSegment(value: 1, label: Text('Medium')),
                ButtonSegment(value: 2, label: Text('High')),
              ],
              selected: {s.sensitivity},
              onSelectionChanged: (v) => store.updateSettings(s.copyWith(sensitivity: v.first)),
            ),
            const SizedBox(height: 8),
            Text(
              'Alarm when combined confidence reaches ${(level * 100).round()}%. '
              'Higher sensitivity catches more, but may raise more false alarms.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ]),
          const SizedBox(height: 12),
          section('Cancel countdown: ${s.countdownSeconds} s', [
            Slider(
              value: s.countdownSeconds.toDouble(),
              min: 5,
              max: 30,
              divisions: 5,
              label: '${s.countdownSeconds} s',
              onChanged: (v) => store.updateSettings(s.copyWith(countdownSeconds: v.round())),
            ),
            Text(
              'Time you get to cancel a false alarm before contacts are alerted.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ]),
          const SizedBox(height: 12),
          section('Abnormal stop after: ${s.stopAlarmSeconds} s', [
            Slider(
              value: s.stopAlarmSeconds.toDouble(),
              min: 30,
              max: 300,
              divisions: 9,
              label: '${s.stopAlarmSeconds} s',
              onChanged: (v) => store.updateSettings(s.copyWith(stopAlarmSeconds: v.round())),
            ),
            Text(
              'If you were walking and then stop moving for this long, the countdown starts.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ]),
          const SizedBox(height: 12),
          section('How detection works', [
            Text(
              'Three methods analyse every 3 seconds of motion:\n'
              '1. Threshold rules - weight ${(ConfidenceFusion.wThreshold * 100).round()}%\n'
              '2. Statistical jerk / SMA analysis - weight ${(ConfidenceFusion.wStatistical * 100).round()}%\n'
              '3. On-device ML classifier - weight ${(ConfidenceFusion.wMl * 100).round()}%\n\n'
              'An alarm needs the weighted confidence to pass the level above AND at least two methods to agree. '
              'The ML model in this prototype was trained on simulated motion data.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.4),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Changes apply to the next Safe Walk you start.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
