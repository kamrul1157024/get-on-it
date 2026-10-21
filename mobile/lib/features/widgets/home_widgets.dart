import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import '../../data/database.dart';
import '../../data/repository.dart';
import 'widget_data.dart';

/// The native widgets (android/.../widget/). Tests use a fake.
abstract class WidgetBridge {
  Future<void> save(Map<String, String> data);

  Future<void> refresh();
}

class HomeWidgetBridge implements WidgetBridge {
  const HomeWidgetBridge();

  static const receivers = ['app.getonit.widget.TodayWidgetReceiver', 'app.getonit.widget.GoalWidgetReceiver'];

  @override
  Future<void> save(Map<String, String> data) async {
    for (final e in data.entries) {
      await HomeWidget.saveWidgetData<String>(e.key, e.value);
    }
  }

  @override
  Future<void> refresh() async {
    for (final r in receivers) {
      await HomeWidget.updateWidget(qualifiedAndroidName: r);
    }
  }
}

final widgetBridgeProvider = Provider<WidgetBridge>((ref) => const HomeWidgetBridge());

/// Keeps the widgets in step with the data: after each change, at a new
/// day, and when settings change. Spec §10.6.
final widgetSyncProvider = NotifierProvider<WidgetSync, int>(WidgetSync.new);

class WidgetSync extends Notifier<int> {
  Timer? _debounce;
  StreamSubscription<void>? _changes;

  @override
  int build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _changes?.cancel();
    });
    _changes = ref.read(repositoryProvider).changes.listen((_) => schedule());
    ref.listen(currentDayProvider, (_, _) => schedule());
    ref.listen(settingsProvider, (_, _) => schedule());
    schedule();
    return 0;
  }

  void schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), push);
  }

  Future<void> push() async {
    final now = ref.read(wallClockProvider)();
    final data = buildWidgetData(await computeGoalViews(ref.read(repositoryProvider), now), now);
    try {
      final bridge = ref.read(widgetBridgeProvider);
      await bridge.save(data);
      await bridge.refresh();
      state++;
    } catch (e) {
      debugPrint('Widget update failed: $e');
    }
  }
}

/// Handles a widget button that only writes data, for example "Done" or
/// "+1". [uri] is `getonit://widget?json=<action>`.
Future<bool> handleWidgetUri(Repository repo, Uri? uri, DateTime now) async {
  final json = uri?.queryParameters['json'];
  if (json == null) return false;
  final action = (jsonDecode(json) as Map).cast<String, Object?>();
  if (!dataActions.contains(action['type'])) return false;
  final goalId = ((action['params'] as Map?)?['goalId']) as String?;
  if (goalId == null) return false;
  final view = (await computeGoalViews(repo, now)).where((v) => v.goal.id == goalId).firstOrNull;
  if (view == null) return false;
  await runDataAction(repo, view, action);
  return true;
}

/// Runs in a background isolate when a widget button is tapped while the
/// app may be closed: writes the event, then redraws the widgets.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase();
  try {
    final repo = Repository(db);
    final now = DateTime.now();
    if (await handleWidgetUri(repo, uri, now)) {
      const bridge = HomeWidgetBridge();
      await bridge.save(buildWidgetData(await computeGoalViews(repo, now), now));
      await bridge.refresh();
    }
  } finally {
    await db.close();
  }
}
