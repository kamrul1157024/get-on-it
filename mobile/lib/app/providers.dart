import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import '../core/time/day_clock.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../engines/engine.dart';
import '../engines/registry.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// The wall clock. Tests override it to move through days.
final wallClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final repositoryProvider = Provider<Repository>(
  (ref) => Repository(ref.watch(databaseProvider), clock: ref.watch(wallClockProvider)),
);

const builtinTemplateAssets = [
  'assets/templates/course.json',
  'assets/templates/book.json',
  'assets/templates/habit.json',
];

/// Installs the built-in templates on start. A newer version in the app
/// replaces an older installed one.
final bootstrapProvider = FutureProvider<void>((ref) async {
  final repo = ref.watch(repositoryProvider);
  for (final asset in builtinTemplateAssets) {
    final json = (jsonDecode(await rootBundle.loadString(asset)) as Map).cast<String, Object?>();
    await repo.installTemplate(TemplateDoc(json), source: 'builtin');
  }
});

final templatesProvider = StreamProvider<Map<String, TemplateDoc>>(
  (ref) => ref.watch(repositoryProvider).watchTemplates(),
);

final goalsProvider = StreamProvider<List<StoredGoal>>((ref) => ref.watch(repositoryProvider).watchGoals());

final eventsProvider = StreamProvider.family<List<GoalEvent>, String>(
  (ref, goalId) => ref.watch(repositoryProvider).watchEvents(goalId),
);

final linkedFilesProvider = StreamProvider.family<Map<String, String>, String>(
  (ref, goalId) => ref.watch(repositoryProvider).watchLinkedFiles(goalId),
);

final settingsProvider = StreamProvider<Map<String, String>>((ref) => ref.watch(repositoryProvider).watchSettings());

final dayClockProvider = Provider<DayClock>((ref) {
  final s = ref.watch(settingsProvider).value ?? const {};
  return DayClock(dayStartHour: int.tryParse(s['dayStartHour'] ?? '') ?? 0);
});

/// The current day number. It changes at the day boundary, and when the app
/// resumes, so every goal state is recalculated for the new day.
final currentDayProvider = NotifierProvider<CurrentDay, int>(CurrentDay.new);

class CurrentDay extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    final clock = ref.watch(dayClockProvider);
    final now = ref.watch(wallClockProvider)();
    final day = clock.dayOfDateTime(now);
    _timer?.cancel();
    // Wake just after the next boundary.
    final next = DayClock.dateOf(day + 1)
        .add(Duration(hours: clock.dayStartHour, minutes: -now.timeZoneOffset.inMinutes, seconds: 1));
    final wait = next.difference(now.toUtc());
    _timer = Timer(wait.isNegative ? const Duration(minutes: 1) : wait, refresh);
    ref.onDispose(() => _timer?.cancel());
    return day;
  }

  void refresh() {
    final d = ref.read(dayClockProvider).dayOfDateTime(ref.read(wallClockProvider)());
    if (d != state) state = d;
  }
}

const engineRegistry = EngineRegistry();

class GoalView {
  const GoalView({required this.goal, required this.template, required this.state, required this.createdAt});

  final GoalDoc goal;
  final TemplateDoc? template;
  final Map<String, Object?> state;
  final DateTime createdAt;

  /// The render scope for this goal. Spec §6.1.
  Map<String, Object?> get scope => {'goal': goal.scopeValue, 'data': goal.data, 'state': state};
}

/// Goal + template + computed state. Recomputed when an event arrives, the
/// goal changes, a file is linked, or the day changes.
final goalViewProvider = Provider.family<GoalView?, String>((ref, goalId) {
  final goals = ref.watch(goalsProvider).value;
  final stored = goals?.where((g) => g.doc.id == goalId).firstOrNull;
  if (stored == null) return null;
  final template = ref.watch(templatesProvider).value?[stored.doc.templateRef];
  final events = ref.watch(eventsProvider(goalId)).value ?? const [];
  final files = ref.watch(linkedFilesProvider(goalId)).value ?? const {};
  final clock = ref.watch(dayClockProvider);
  ref.watch(currentDayProvider);
  final now = Now.of(ref.read(wallClockProvider)());

  final engine = template == null ? null : engineRegistry.forGoal(template, stored.doc);
  final state = engine == null
      ? const <String, Object?>{}
      : engine.computeState(
          EngineContext(
            goal: stored.doc,
            events: events,
            now: now,
            clock: clock,
            importedDay: clock.dayOfDateTime(stored.createdAt),
            linkedFiles: files,
          ),
        );
  return GoalView(goal: stored.doc, template: template, state: state, createdAt: stored.createdAt);
});

/// The state a goal would have, before it is saved: for the import preview
/// and its checks.
Map<String, Object?> previewState(
  TemplateDoc template,
  GoalDoc goal, {
  required DayClock clock,
  required DateTime now,
  List<GoalEvent> events = const [],
  DateTime? createdAt,
  Map<String, String> files = const {},
}) {
  final engine = engineRegistry.forGoal(template, goal);
  if (engine == null) return const {};
  return engine.computeState(
    EngineContext(
      goal: goal,
      events: events,
      now: Now.of(now),
      clock: clock,
      importedDay: clock.dayOfDateTime(createdAt ?? now),
      linkedFiles: files,
    ),
  );
}
