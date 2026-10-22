import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/nudges/time_lost_card.dart';
import '../features/permissions/permission_prompt.dart';
import '../features/update/update_dialog.dart';
import '../features/drive/drive_controller.dart';
import '../features/goal/goal_screen.dart';
import '../features/nudges/nudges.dart';
import '../features/reminders/alarm_screen.dart';
import '../features/widgets/home_widgets.dart';
import '../features/reminders/reminders_controller.dart';
import '../features/import/import_screen.dart';
import '../features/intents/incoming.dart';
import '../features/today/today_screen.dart';
import '../actions/action_router.dart';
import 'providers.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class GetOnItApp extends ConsumerStatefulWidget {
  const GetOnItApp({super.key, this.listenForIntents = true, this.startReminders = true});

  final bool listenForIntents;
  final bool startReminders;

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

  bool _remindersStarted = false;
  bool _updateChecked = false;

  /// Once per start: the permission popup first, then the update dialog, so
  /// the two never stack.
  Future<void> _afterStart() async {
    if (_updateChecked) return;
    _updateChecked = true;
    var ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    await runFirstStartSetup(ctx, ref);
    ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) await checkForUpdateOnStart(ctx, ref);
  }

  void _startReminders() {
    if (_remindersStarted || !widget.startReminders) return;
    _remindersStarted = true;
    ref.read(remindersProvider.notifier).start(_onReminderTap);
  }

  /// A tap on a reminder, or on its Done / Snooze button.
  Future<void> _onReminderTap(String payload, String? action) async {
    final p = decodePayload(payload);
    final goalId = p['goalId'] as String?;
    if (goalId == null) return;
    final reminders = ref.read(remindersProvider.notifier);
    if (action == 'done') {
      final view = ref.read(goalViewProvider(goalId));
      if (view != null) await completeToday(ref.read(repositoryProvider), view);
      return;
    }
    if (action == 'snooze') {
      await reminders.ringAgain(p, ((p['snoozeMin'] as num?) ?? 10).toInt());
      return;
    }
    final level = p['level'];
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) =>
            level == 'alarm' || level == 'strict_alarm' ? AlarmScreen(payload: p) : GoalScreen(goalId: goalId),
      ),
    );
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
    if (state == AppLifecycleState.resumed) {
      ref.read(currentDayProvider.notifier).refresh();
      // The user may have changed a permission in system settings.
      if (_remindersStarted) ref.read(remindersProvider.notifier).refreshPermissions();
      if (widget.startReminders) ref.read(nudgesProvider.notifier).refreshStatus();
      // Time in other apps grew while this one was away.
      ref.invalidate(timeLostProvider);
      ref.invalidate(overlayAllowedProvider);
    }
    // A change that waits for the automatic backup goes up now.
    if (state == AppLifecycleState.paused) ref.read(driveProvider.notifier).flush();
  }

  /// Shared or opened JSON goes to the import screen. Links are routes
  /// (spec §8.4): `getonit://import`, `getonit://goal/<id>`, and
  /// `getonit://start/<id>`, which opens today's work (used by nudges).
  void _openIncoming(String text) {
    if (text.startsWith('getonit://')) {
      final uri = Uri.parse(text);
      final id = uri.pathSegments.firstOrNull;
      final nav = navigatorKey.currentState;
      switch (uri.host) {
        case 'import':
          nav?.push(MaterialPageRoute(builder: (_) => const ImportScreen()));
        case 'goal' when id != null:
          nav?.push(MaterialPageRoute(builder: (_) => GoalScreen(goalId: id)));
        // A widget button that opens something: the action runs as if tapped
        // in the app. Only known action types do anything.
        case 'action':
          final json = uri.queryParameters['json'];
          final ctx = navigatorKey.currentContext;
          if (json != null && ctx != null) {
            ActionRouter(ctx, ref).call((jsonDecode(json) as Map).cast<String, Object?>());
          }
        case 'start' when id != null:
          final view = ref.read(goalViewProvider(id));
          final ctx = navigatorKey.currentContext;
          if (view != null && ctx != null) ActionRouter(ctx, ref).call(startWorkAction(view));
      }
      return;
    }
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => ImportScreen(initialText: text)));
  }

  @override
  Widget build(BuildContext context) {
    final boot = ref.watch(bootstrapProvider);
    // Keeps the nudge service's copy of today's work current.
    if (widget.startReminders) {
      ref.listen(nudgesProvider, (_, _) {});
      // Keeps the home-screen widgets current.
      ref.listen(widgetSyncProvider, (_, _) {});
    }
    const seed = Color(0xFF7C5CFA);
    return MaterialApp(
      title: 'Get On It',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: boot.when(
        data: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _startReminders();
            _afterStart();
          });
          return const TodayScreen();
        },
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(body: Center(child: Text('Could not start: $e'))),
      ),
    );
  }
}
