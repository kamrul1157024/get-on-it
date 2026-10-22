import '../../core/schema/documents.dart';
import '../../core/time/clock_format.dart';
import 'planner.dart';

/// Reminder levels in plain words.
String levelName(ReminderLevel l) => switch (l) {
  ReminderLevel.notification => 'notification',
  ReminderLevel.sticky => 'notification that stays',
  ReminderLevel.alarm => 'alarm',
  ReminderLevel.strictAlarm => 'alarm that rings until you start',
};

/// A goal's reminders, step by step: "7:00 PM notification → 7:30 PM alarm".
String ladderDescription(GoalDoc goal, {required bool use24h}) =>
    [for (final s in ladderOf(goal)) '${clockDisplay(s.minuteOfDay, use24h: use24h)} ${levelName(s.level)}']
        .join(' → ');

/// The goal-menu entry: "Turn reminders on (strict, from 7:00 PM)".
String turnOnLabel(GoalDoc goal, {required bool use24h}) {
  final steps = ladderOf(goal);
  final preset = presetOf(goal);
  if (steps.isEmpty) return 'Turn reminders on ($preset)';
  return 'Turn reminders on ($preset, from ${clockDisplay(steps.first.minuteOfDay, use24h: use24h)})';
}
