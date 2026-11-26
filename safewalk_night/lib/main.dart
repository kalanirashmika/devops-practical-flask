import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'detection/fall_model.dart';
import 'detection/tflite_fall_model.dart';
import 'screens/alert_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/map_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_store.dart';
import 'services/session_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore(PrefsBackend())..load();
  runApp(SafeWalkApp(store: store, modelLoader: loadFallModel));
}

class SafeWalkApp extends StatelessWidget {
  final AppStore store;
  final Future<FallModel> Function() modelLoader;

  const SafeWalkApp({super.key, required this.store, required this.modelLoader});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B6CFF),
      brightness: Brightness.dark,
      surface: const Color(0xFF0E1224),
    );
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppStore>.value(value: store),
        ChangeNotifierProvider<SessionController>(
          create: (_) => SessionController(store: store, modelLoader: modelLoader),
        ),
      ],
      child: MaterialApp(
        title: 'SafeWalk Night',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: scheme,
          useMaterial3: true,
          scaffoldBackgroundColor: scheme.surface,
          cardTheme: CardThemeData(
            color: const Color(0xFF171C36),
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
        ),
        home: const RootShell(),
      ),
    );
  }
}

/// Bottom-navigation shell. While an alarm is active the alert screen takes
/// over the whole app, whichever tab was open.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final phase = context.select<SessionController, SessionPhase>((c) => c.phase);
    if (phase == SessionPhase.countdown || phase == SessionPhase.alertSent) {
      return const AlertScreen();
    }
    final Widget body = switch (_tab) {
      0 => HomeScreen(onOpenContacts: () => setState(() => _tab = 2)),
      1 => const MapScreen(),
      2 => const ContactsScreen(),
      3 => const HistoryScreen(),
      _ => const SettingsScreen(),
    };
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.shield_moon_outlined), selectedIcon: Icon(Icons.shield_moon), label: 'Walk'),
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.group_outlined), selectedIcon: Icon(Icons.group), label: 'Contacts'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}
