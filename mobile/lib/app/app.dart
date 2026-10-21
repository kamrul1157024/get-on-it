import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/drive/drive_controller.dart';
import '../features/import/import_screen.dart';
import '../features/intents/incoming.dart';
import '../features/today/today_screen.dart';
import 'providers.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class GetOnItApp extends ConsumerStatefulWidget {
  const GetOnItApp({super.key, this.listenForIntents = true});

  final bool listenForIntents;

  @override
  ConsumerState<GetOnItApp> createState() => _GetOnItAppState();
}

class _GetOnItAppState extends ConsumerState<GetOnItApp> with WidgetsBindingObserver {
  StreamSubscription<String>? _intents;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.listenForIntents) {
      _intents = IncomingIntents.stream.listen(_openIncoming);
      IncomingIntents.initial().then((t) {
        if (t != null) _openIncoming(t);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intents?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A new day may have started while the app was in the background.
    if (state == AppLifecycleState.resumed) ref.read(currentDayProvider.notifier).refresh();
    // A change that waits for the automatic backup goes up now.
    if (state == AppLifecycleState.paused) ref.read(driveProvider.notifier).flush();
  }

  /// Shared or opened JSON goes to the import screen. Links are routes.
  void _openIncoming(String text) {
    if (text.startsWith('getonit://')) {
      final uri = Uri.parse(text);
      if (uri.host == 'import') {
        navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => const ImportScreen()));
      }
      return;
    }
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ImportScreen(initialText: text)));
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(bootstrapProvider);
    const seed = Color(0xFF7C5CFA);
    return MaterialApp(
      title: 'Get On It',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: boot.when(
        data: (_) => const TodayScreen(),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(body: Center(child: Text('Could not start: $e'))),
      ),
    );
  }
}
