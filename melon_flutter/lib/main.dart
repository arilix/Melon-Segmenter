import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'store/auth_manager.dart';
import 'store/melon_store.dart';
import 'store/schedule_store.dart';
import 'theme.dart';
import 'ui/login_screen.dart';
import 'ui/melon_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = MelonStore();
  final schedule = ScheduleStore();
  final auth = AuthManager();
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider.value(value: schedule),
      ChangeNotifierProvider.value(value: auth),
    ],
    child: const MelonApp(),
  ));
  // Load in the background; the root shows a spinner until the library is ready.
  await store.load();
  await schedule.load();
  await auth.restore();
}

class MelonApp extends StatelessWidget {
  const MelonApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Melon Segmenter',
        debugShowCheckedModeBanner: false,
        theme: MelonTheme.data,
        builder: (context, child) => MelonBackground(child: child!),
        home: const _Root(),
      );
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool _skipped = false;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MelonStore>();
    final auth = context.watch<AuthManager>();
    if (!store.ready || auth.isRestoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: MelonTheme.accentTeal)));
    }
    if (auth.user == null && !_skipped) {
      return LoginScreen(onSkip: () => setState(() => _skipped = true));
    }
    return const MelonListScreen();
  }
}
