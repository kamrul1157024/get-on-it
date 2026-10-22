import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../core/events/goal_event.dart';
import '../core/schema/documents.dart';
import '../core/time/day_clock.dart';

/// Everything an engine may read. Engines are pure: the same context always
/// gives the same state.
class EngineContext {
  EngineContext({
    required this.goal,
    required List<GoalEvent> events,
    required this.now,
    this.clock = const DayClock(),
    this.importedDay,
    this.linkedFiles = const {},
  }) : events = [...events]..sort(GoalEvent.compare);

  final GoalDoc goal;
  final List<GoalEvent> events;
  final Now now;
  final DayClock clock;

  /// The day the goal was first imported; the start when the goal sets none.
  final int? importedDay;

  /// documentId → reference of a linked file (PDF path, Drive id, …).
  final Map<String, String> linkedFiles;

  late final int today = clock.dayOf(now.utcMs, now.offsetMinutes);
  late final int startDay = goal.startDay ?? importedDay ?? _firstEventDay ?? today;
  int? get deadlineDay => goal.deadlineDay;
  late final Set<int> _schedule = goal.scheduleDays;

  int? get _firstEventDay => events.isEmpty ? null : dayOf(events.first);

  Map<String, Object?> get data => goal.data;

  int dayOf(GoalEvent e) => clock.dayOf(e.utcMs, e.offsetMinutes);

  bool isScheduled(int day) => _schedule.contains(DayClock.weekdayOf(day));

  late final Set<int> skippedDays = {
    for (final e in events)
      if (e.type == EventType.daySkipped) DayClock.parseDate(e['date']) ?? dayOf(e),
  };

  Iterable<GoalEvent> ofType(String type) => events.where((e) => e.type == type);

  /// Scheduled days in [from]..[to], both included.
  int scheduledDaysBetween(int from, int to) {
    var n = 0;
    for (var d = from; d <= to; d++) {
      if (isScheduled(d)) n++;
    }
    return n;
  }
}

abstract class ProgressEngine {
  String get id;

  Map<String, Object?> computeState(EngineContext c);

  /// A one-line description for the import preview.
  String summary(GoalDoc goal);
}

/// Values that every engine returns. Spec §7.2.
///
/// [progress] is 0–1 overall progress. [dayComplete] says whether a given day
/// met its target; the streak, week dots and heatmap are built from it.
Map<String, Object?> commonState(
  EngineContext c, {
  required double progress,
  required bool Function(int day) dayComplete,
  bool Function(int day)? dayActive,
  String? progressLabel,
}) {
  final p = progress.clamp(0.0, 1.0);
  final todayComplete = dayComplete(c.today);
  final active = dayActive ?? _activeDays(c);

  // Streak: walk back through scheduled days. Today only adds; it never
  // breaks the streak while it is still in progress.
  var streak = todayComplete ? 1 : 0;
  for (var d = c.today - 1; d >= c.startDay && d > c.today - 3660; d--) {
    if (!c.isScheduled(d) || c.skippedDays.contains(d)) continue;
    if (!dayComplete(d)) break;
    streak++;
  }

  // This week, Monday to Sunday.
  final monday = c.today - (DayClock.weekdayOf(c.today) - 1);
  const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  final week = [
    for (var i = 0; i < 7; i++) {'d': letters[i], 's': _weekStatus(c, monday + i, dayComplete)},
  ];

  // Last 12 weeks, oldest first. 4 = complete, 2 = some activity.
  final heatStart = monday - 7 * 11;
  final heatmap = [
    for (var d = heatStart; d < monday + 7; d++)
      {
        'date': DayClock.isoDate(d),
        'level': d > c.today
            ? -1
            : dayComplete(d)
            ? 4
            : active(d)
            ? 2
            : 0,
      },
  ];

  return {
    'progress': p,
    'pctLabel': '${(p * 100).round()}%',
    'progressLabel': progressLabel ?? '${(p * 100).round()}% done',
    'isComplete': p >= 1.0,
    'todayComplete': todayComplete,
    // Bindings cannot negate, so the opposite is a value of its own.
    'todayPending': !todayComplete,
    'todayScheduled': c.isScheduled(c.today),
    'streak': streak,
    'streakLabel': streak == 1 ? '1 day' : '$streak days',
    'pace': pace(c, p, todayComplete),
    'deadlineLabel': deadlineLabel(c),
    'week': week,
    'heatmap': heatmap,
    'todayLabel': DateFormat('EEEE, d MMM').format(DayClock.dateOf(c.today)),
  };
}

String _weekStatus(EngineContext c, int day, bool Function(int) dayComplete) {
  if (day > c.today) return c.isScheduled(day) ? '' : 'rest';
  if (day == c.today) return dayComplete(day) ? 'done' : 'today';
  if (day >= c.startDay && dayComplete(day)) return 'done';
  return c.isScheduled(day) ? '' : 'rest';
}

bool Function(int) _activeDays(EngineContext c) {
  final days = {for (final e in c.events) c.dayOf(e)};
  return days.contains;
}

/// Compares actual progress with a linear target over the scheduled days
/// from start to deadline. One day's worth of work is the tolerance.
Map<String, Object?> pace(EngineContext c, double progress, bool todayComplete) {
  final deadline = c.deadlineDay;
  if (deadline == null || deadline < c.startDay) {
    return {'status': 'none', 'label': '', 'tone': 'neutral', 'behindDays': 0};
  }
  final total = math.max(1, c.scheduledDaysBetween(c.startDay, deadline));
  final passed =
      c.scheduledDaysBetween(c.startDay, math.min(c.today - 1, deadline)) +
      (todayComplete && c.isScheduled(c.today) ? 1 : 0);
  final expected = passed / total;
  final share = 1 / total;
  final gap = expected - progress;
  if (progress >= 1) {
    return {'status': 'ahead', 'label': 'Finished', 'tone': 'success', 'behindDays': 0};
  }
  if (gap > share + 1e-9) {
    final days = (gap / share).ceil();
    return {
      'status': 'behind',
      'label': days == 1 ? '1 day behind' : '$days days behind',
      'tone': days > 7 ? 'danger' : 'warning',
      'behindDays': days,
    };
  }
  if (-gap > share + 1e-9) {
    return {'status': 'ahead', 'label': 'Ahead', 'tone': 'success', 'behindDays': 0};
  }
  return {'status': 'on_track', 'label': 'On track', 'tone': 'success', 'behindDays': 0};
}

String deadlineLabel(EngineContext c) {
  final d = c.deadlineDay;
  if (d == null) return '';
  final left = d - c.today;
  if (left < 0) return 'Overdue';
  if (left == 0) return 'Due today';
  return left == 1 ? '1 day' : '$left days';
}

String shortDate(int day) => DateFormat('d MMM').format(DayClock.dateOf(day));

String minutesLabel(num seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

/// A place in a video, spelled out: "34 min 12 s", "1 h 5 min", "45 s".
/// Not "34:12", which reads like a clock time.
String positionLabel(num seconds) {
  final s = seconds.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) return m == 0 ? '$h h' : '$h h $m min';
  if (m == 0) return '$sec s';
  return sec == 0 ? '$m min' : '$m min $sec s';
}

num? asNum(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
