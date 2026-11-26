import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/app_store.dart';
import 'home_screen.dart' show formatDuration;

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  static String _when(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}  ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walk history'),
        actions: [
          if (store.history.isNotEmpty)
            IconButton(tooltip: 'Clear history', icon: const Icon(Icons.delete_sweep_outlined), onPressed: store.clearHistory),
        ],
      ),
      body: store.history.isEmpty
          ? const Center(child: Text('Your finished Safe Walks will appear here.'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: store.history.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = store.history[i];
                final alert = r.outcome.contains(WalkRecord.alertSent);
                final cancelled = r.outcome.toLowerCase().contains('cancel');
                return Card(
                  child: ListTile(
                    leading: Icon(
                      alert ? Icons.notifications_active : (cancelled ? Icons.report_gmailerrorred : Icons.check_circle),
                      color: alert ? const Color(0xFFE5484D) : (cancelled ? Colors.amber : const Color(0xFF2FBF71)),
                    ),
                    title: Text(r.outcome),
                    subtitle: Text(
                      '${_when(r.startedAt)}  ·  ${formatDuration(r.duration)}'
                      '${r.alarms > 0 ? '  ·  ${r.alarms} alarm(s)' : ''}'
                      '${r.peakConfidence > 0 ? '  ·  peak ${(r.peakConfidence * 100).round()}%' : ''}',
                    ),
                  ),
                );
              },
            ),
    );
  }
}
