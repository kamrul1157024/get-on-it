import 'dart:convert';

import '../../core/events/goal_event.dart';
import '../../core/schema/documents.dart';
import '../../core/time/day_clock.dart';

/// Reminder levels, from gentle to strict. Spec §11.1.
enum ReminderLevel {
  notification,
  sticky,
  alarm,
  strictAlarm;

  static ReminderLevel parse(Object? v) => switch (v) {
    'sticky' => sticky,
    'alarm' => alarm,
    'strict_alarm' => strictAlarm,
    _ => notification,
  };

  bool get isAlarm => this == alarm || this == strictAlarm;
  String get wire => this == strictAlarm ? 'strict_alarm' : name;
}

/// One step of an escalation ladder. Spec §11.2.
class LadderStep {
  const LadderStep({
    required this.minuteOfDay,
    required this.level,
    this.maxSnoozes = 2,
    this.snoozeMin = 10,
    this.dismiss = 'start_task',
    this.minMinutes,
    this.minPages,
  });

  final int minuteOfDay;
  final ReminderLevel level;
  final int maxSnoozes;
  final int snoozeMin;

  /// `do_task` or `start_task` (strict alarms only). Spec §11.4.
  final String dismiss;
  final int? minMinutes;
  final int? minPages;
}

int? parseClock(Object? v) {
  if (v is! String) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v);
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

String clockText(int minuteOfDay) =>
    '${(minuteOfDay ~/ 60).toString().padLeft(2, '0')}:${(minuteOfDay % 60).toString().padLeft(2, '0')}';

/// The ladder a goal proposes, from a preset or an explicit list. Spec §11.3.
List<LadderStep> ladderOf(GoalDoc goal) {
  final r = goal.reminders;
  if (r == null) return const [];
  final ladder = r['ladder'];
  if (ladder is List && ladder.isNotEmpty) {
    return [
      for (final s in ladder.whereType<Map>())
        if (parseClock(s['at']) != null)
          LadderStep(
            minuteOfDay: parseClock(s['at'])!,
            level: ReminderLevel.parse(s['level']),
            maxSnoozes: (s['maxSnoozes'] as num?)?.toInt() ?? 2,
            snoozeMin: (s['snoozeMin'] as num?)?.toInt() ?? 10,
            dismiss: ((s['dismiss'] as Map?)?['type'] as String?) ?? 'start_task',
            minMinutes: (((s['dismiss'] as Map?)?['minProgress'] as Map?)?['minutes'] as num?)?.toInt(),
            minPages: (((s['dismiss'] as Map?)?['minProgress'] as Map?)?['pages'] as num?)?.toInt(),
          ),
    ]..sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
  }
  final t = parseClock(r['time']) ?? 19 * 60;
  return switch (r['preset']) {
    'firm' => [
      LadderStep(minuteOfDay: t, level: ReminderLevel.notification),
      LadderStep(minuteOfDay: t + 30, level: ReminderLevel.sticky),
      LadderStep(minuteOfDay: t + 60, level: ReminderLevel.alarm),
    ],
    'strict' => [
      LadderStep(minuteOfDay: t, level: ReminderLevel.notification),
      LadderStep(minuteOfDay: t + 30, level: ReminderLevel.sticky),
      LadderStep(minuteOfDay: t + 60, level: ReminderLevel.alarm),
      LadderStep(minuteOfDay: t + 90, level: ReminderLevel.strictAlarm, dismiss: 'do_task', minMinutes: 5, minPages: 2),
    ],
    _ => [LadderStep(minuteOfDay: t, level: ReminderLevel.notification)],
  }.where((s) => s.minuteOfDay < 24 * 60).toList();
}

String presetOf(GoalDoc goal) {
  final r = goal.reminders;
  if (r == null) return 'none';
  if (r['ladder'] is List) return 'custom';
  return (r['preset'] as String?) ?? 'gentle';
}

/// Global rules the user controls. A document cannot change them. Spec §11.5.
class ReminderRules {
  const ReminderRules({
    this.quietStart = 23 * 60,
    this.quietEnd = 7 * 60,
    this.dailyAlarmLimit = 6,
    this.pausedUntilDay,
  });

  factory ReminderRules.fromSettings(Map<String, String> s) => ReminderRules(
    quietStart: parseClock(s['reminders.quietStart']) ?? 23 * 60,
    quietEnd: parseClock(s['reminders.quietEnd']) ?? 7 * 60,
    pausedUntilDay: DayClock.parseDate(s['reminders.pausedUntil']),
  );

  final int quietStart;
  final int quietEnd;
  final int dailyAlarmLimit;

  /// Reminders are paused up to and including this day.
  final int? pausedUntilDay;

  bool isQuiet(int minuteOfDay) => quietStart > quietEnd
      ? minuteOfDay >= quietStart || minuteOfDay < quietEnd
      : minuteOfDay >= quietStart && minuteOfDay < quietEnd;
}

/// A reminder at a moment in local time.
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.goalId,
    required this.day,
    required this.minuteOfDay,
    required this.step,
    required this.title,
    required this.body,
  });

  /// Stable per goal, day and step, so rescheduling replaces, not adds.
  final int id;
  final String goalId;
  final int day;
  final int minuteOfDay;
  final LadderStep step;
  final String title;
  final String body;

  ReminderLevel get level => step.level;

  DateTime get localTime => DateTime(
    DayClock.dateOf(day).year,
    DayClock.dateOf(day).month,
    DayClock.dateOf(day).day,
    minuteOfDay ~/ 60,
    minuteOfDay % 60,
  );

  String get payload => jsonEncode({
    'goalId': goalId,
    'level': level.wire,
    'day': day,
    'id': id,
    'snoozeMin': step.snoozeMin,
    'maxSnoozes': step.maxSnoozes,
    'dismiss': step.dismiss,
    'minMinutes': step.minMinutes,
    'minPages': step.minPages,
  });
}

/// What the planner needs to know about one goal.
class ReminderInput {
  const ReminderInput({
    required this.goal,
    required this.enabled,
    required this.isDayComplete,
    required this.title,
    required this.body,
  });

  final GoalDoc goal;

  /// The user turned this goal's reminders on.
  final bool enabled;

  /// Whether the target of [day] is already met; only today can be known.
  final bool Function(int day) isDayComplete;
  final String title;
  final String body;
}

int _goalHash(String goalId) {
  var h = 17;
  for (final c in goalId.codeUnits) {
    h = (h * 31 + c) & 0x7ffff;
  }
  return h;
}

int reminderId(String goalId, int day, int step) => (_goalHash(goalId) * 4096 + (day % 512) * 8 + step) & 0x7fffffff;

/// Whether reminder [id] (snoozed or not) can belong to [goalId]. Android
/// gives back a shown notification without its payload, so its id is all
/// there is. The snooze bit shares the hash's top bit, so that bit is not
/// compared.
bool reminderIdIsOf(int id, String goalId) => (id >> 12) & 0x3ffff == _goalHash(goalId) & 0x3ffff;

/// Turns approved ladders into concrete reminders for [days] days from
/// [today], applying the safety rules. Pure: the same input, the same plan.
List<PlannedReminder> planReminders({
  required List<ReminderInput> goals,
  required ReminderRules rules,
  required int today,
  required int nowMinute,
  int days = 7,
}) {
  final out = <PlannedReminder>[];
  for (var day = today; day < today + days; day++) {
    if (rules.pausedUntilDay != null && day <= rules.pausedUntilDay!) continue;
    final dayItems = <PlannedReminder>[];
    for (final g in goals) {
      if (!g.enabled) continue;
      final steps = ladderOf(g.goal);
      if (steps.isEmpty) continue;
      final daysList = (g.goal.reminders?['days'] as List?)?.whereType<String>().toList();
      final scheduled = daysList == null || daysList.isEmpty
          ? g.goal.scheduleDays
          : GoalDoc({
              ...g.goal.json,
              'schedule': {'days': daysList},
            }).scheduleDays;
      if (!scheduled.contains(DayClock.weekdayOf(day))) continue;
      // stopWhen: today_complete. Spec §11.2.
      if (g.isDayComplete(day)) continue;
      for (var i = 0; i < steps.length; i++) {
        final s = steps[i];
        if (rules.isQuiet(s.minuteOfDay)) continue;
        if (day == today && s.minuteOfDay <= nowMinute) continue;
        dayItems.add(
          PlannedReminder(
            id: reminderId(g.goal.id, day, i),
            goalId: g.goal.id,
            day: day,
            minuteOfDay: s.minuteOfDay,
            step: s,
            title: g.title,
            body: g.body,
          ),
        );
      }
    }
    dayItems.sort((a, b) => a.minuteOfDay.compareTo(b.minuteOfDay));
    // At most N alarm-level reminders a day, across all goals; the earliest
    // are kept.
    var alarms = 0;
    for (final r in dayItems) {
      if (r.level.isAlarm) {
        if (alarms >= rules.dailyAlarmLimit) continue;
        alarms++;
      }
      out.add(r);
    }
  }
  return out;
}

/// Whether enough work happened since an alarm started to dismiss a strict
/// alarm. Spec §11.4.
bool challengeMet({
  required String dismiss,
  required List<GoalEvent> events,
  required int sinceUtcMs,
  required bool todayComplete,
  int? minMinutes,
  int? minPages,
  int lastPageAtStart = 0,
  required bool contentOpened,
}) {
  if (todayComplete) return true;
  if (dismiss == 'start_task') return contentOpened;
  final after = events.where((e) => e.utcMs >= sinceUtcMs).toList()..sort(GoalEvent.compare);
  // Watched seconds: forward movement no faster than the clock.
  final last = <String, (double, int)>{};
  var watched = 0.0;
  var maxPage = lastPageAtStart;
  for (final e in after) {
    switch (e.type) {
      case EventType.itemPosition:
        final item = e['item'] as String? ?? '';
        final sec = (e['sec'] as num?)?.toDouble() ?? 0;
        final prev = last[item];
        if (prev != null) {
          final delta = sec - prev.$1;
          final gap = (e.utcMs - prev.$2) / 1000;
          if (delta > 0 && delta <= gap + 5) watched += delta;
        }
        last[item] = (sec, e.utcMs);
      case EventType.pageReached:
        final p = (e['page'] as num?)?.toInt() ?? 0;
        if (p > maxPage) maxPage = p;
      // Real progress only: an undo is not work done.
      case EventType.itemDone when e['done'] != false:
        return true;
      case EventType.stepDone when e['done'] != false:
        return true;
      case EventType.check when e['checked'] != false:
        return true;
      case EventType.countDelta when ((e['delta'] as num?) ?? 0) > 0:
        return true;
    }
  }
  if (minMinutes != null && watched >= minMinutes * 60) return true;
  if (minPages != null && maxPage - lastPageAtStart >= minPages) return true;
  return false;
}
