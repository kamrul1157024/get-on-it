import 'dart:math' as math;

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import '../core/time/day_clock.dart';
import 'engine.dart';

/// Mode flags let one template show the right control without expressions.
Map<String, Object?> _mode(String mode) => {
  'mode': mode,
  'isCount': mode == 'count',
  'isCheck': mode == 'check',
  'isChecklist': mode == 'checklist',
};

/// Sum of deltas toward a daily or weekly target. Spec §7.5.
class CountEngine implements ProgressEngine {
  const CountEngine();

  @override
  String get id => 'count';

  @override
  String summary(GoalDoc goal) {
    final d = goal.data;
    return '${d['target'] ?? 1} ${d['unit'] ?? 'times'} per ${d['period'] ?? 'day'}';
  }

  @override
  Map<String, Object?> computeState(EngineContext c) {
    final target = math.max(1, (asNum(c.data['target']) ?? 1).toInt());
    final unit = (c.data['unit'] as String?) ?? 'times';
    final weekly = c.data['period'] == 'week';
    final byDay = <int, int>{};
    for (final e in c.ofType(EventType.countDelta)) {
      final day = c.dayOf(e);
      byDay[day] = (byDay[day] ?? 0) + (asNum(e['delta']) ?? 0).toInt();
    }

    int sumFor(int day) {
      if (!weekly) return math.max(0, byDay[day] ?? 0);
      final monday = day - (DayClock.weekdayOf(day) - 1);
      var s = 0;
      for (var d = monday; d <= day; d++) {
        s += byDay[d] ?? 0;
      }
      return math.max(0, s);
    }

    final count = sumFor(c.today);
    return {
      ...commonState(
        c,
        progress: count / target,
        dayComplete: (day) => sumFor(day) >= target,
        dayActive: (day) => (byDay[day] ?? 0) != 0,
        progressLabel: '$count / $target $unit',
      ),
      ..._mode('count'),
      'count': count,
      'target': target,
      'label': '$count / $target $unit',
      'periodLabel': weekly ? 'this week' : 'today',
    };
  }
}

/// A daily yes/no habit, or an "avoid" habit where a check is a slip.
/// Spec §7.6.
class CheckEngine implements ProgressEngine {
  const CheckEngine();

  @override
  String get id => 'check';

  @override
  String summary(GoalDoc goal) => goal.data['avoid'] == true ? 'avoid habit' : 'daily check';

  @override
  Map<String, Object?> computeState(EngineContext c) {
    final avoid = c.data['avoid'] == true;
    final byDay = <int, bool>{};
    for (final e in c.ofType(EventType.check)) {
      byDay[c.dayOf(e)] = e['checked'] != false;
    }
    final checked = byDay[c.today] ?? false;
    bool dayComplete(int day) => avoid ? !(byDay[day] ?? false) : (byDay[day] ?? false);

    int? lastSlip;
    if (avoid) {
      for (final e in byDay.entries) {
        if (e.value && (lastSlip == null || e.key > lastSlip)) lastSlip = e.key;
      }
    }
    final cleanDays = c.today - (lastSlip ?? (c.startDay - 1)) - (checked ? 0 : 1);

    return {
      ...commonState(
        c,
        progress: dayComplete(c.today) ? 1 : 0,
        dayComplete: dayComplete,
        progressLabel: avoid ? (checked ? 'Slipped today' : 'Clean today') : (checked ? 'Done today' : 'Not done yet'),
      ),
      ..._mode('check'),
      'avoid': avoid,
      'checked': checked,
      'cleanDays': math.max(0, cleanDays),
      'cleanDaysLabel': '${math.max(0, cleanDays)} clean days',
      'buttonLabel': avoid ? (checked ? 'Undo slip' : 'I slipped') : (checked ? 'Done ✓' : 'Mark done'),
    };
  }
}

/// A list of steps that resets daily, or a one-time list. Spec §7.7.
class ChecklistEngine implements ProgressEngine {
  const ChecklistEngine();

  @override
  String get id => 'checklist';

  static List<Map<String, Object?>> _steps(Map<String, Object?> data) => [
    for (final s in (data['steps'] as List? ?? const []))
      if (s is Map) s.cast<String, Object?>(),
  ];

  @override
  String summary(GoalDoc goal) {
    final n = _steps(goal.data).length;
    return '$n ${n == 1 ? 'step' : 'steps'}${goal.data['resets'] == 'never' ? '' : ' · daily'}';
  }

  @override
  Map<String, Object?> computeState(EngineContext c) {
    final steps = _steps(c.data);
    final daily = c.data['resets'] != 'never';
    // Latest value per (day, step), and overall latest per step.
    final byDay = <int, Map<String, bool>>{};
    final latest = <String, bool>{};
    final touched = <int>{};
    for (final e in c.ofType(EventType.stepDone)) {
      final step = e['step'];
      if (step is! String) continue;
      final day = c.dayOf(e);
      final done = e['done'] != false;
      (byDay[day] ??= {})[step] = done;
      latest[step] = done;
      if (done) touched.add(day);
    }

    bool doneOn(String step, int day) => daily ? (byDay[day]?[step] ?? false) : (latest[step] ?? false);
    bool dayComplete(int day) =>
        daily ? steps.isNotEmpty && steps.every((s) => doneOn(s['id'] as String, day)) : touched.contains(day);

    final stepStates = [
      for (final s in steps) {'id': s['id'], 'title': s['title'], 'done': doneOn(s['id'] as String, c.today)},
    ];
    final doneCount = stepStates.where((s) => s['done'] == true).length;

    return {
      ...commonState(
        c,
        progress: steps.isEmpty ? 0 : doneCount / steps.length,
        dayComplete: dayComplete,
        progressLabel: '$doneCount of ${steps.length} steps',
      ),
      ..._mode('checklist'),
      'steps': stepStates,
      'doneCount': doneCount,
      'label': '$doneCount / ${steps.length}',
    };
  }
}
