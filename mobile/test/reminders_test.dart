import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/features/reminders/planner.dart';

import 'support/harness.dart';

void main() {
  // Wednesday 21 October 2026.
  final today = DayClock.parseDate('2026-10-21')!;

  GoalDoc g(String id, Map<String, Object?> reminders, {List<String>? days}) => GoalDoc({
    'kind': 'goal',
    'schemaVersion': '1.0',
    'id': id,
    'template': 'habit@1',
    'title': 'Goal $id',
    'data': {'mode': 'check'},
    'reminders': reminders,
    if (days != null) 'schedule': {'days': days},
  });

  ReminderInput input(GoalDoc goal, {bool enabled = true, bool todayDone = false}) => ReminderInput(
    goal: goal,
    enabled: enabled,
    isDayComplete: (d) => d == today && todayDone,
    title: goal.title,
    body: 'body',
  );

  List<PlannedReminder> plan(
    List<ReminderInput> goals, {
    int nowMinute = 9 * 60,
    ReminderRules rules = const ReminderRules(),
    int days = 7,
  }) => planReminders(goals: goals, rules: rules, today: today, nowMinute: nowMinute, days: days);

  List<String> onDay(List<PlannedReminder> p, int day) => [
    for (final r in p)
      if (r.day == day) '${clockText(r.minuteOfDay)} ${r.level.wire}',
  ];

  test('gentle: one notification on every scheduled day', () {
    final p = plan([
      input(g('a', {'preset': 'gentle', 'time': '21:30'})),
    ]);
    expect(p, hasLength(7));
    expect(onDay(p, today), ['21:30 notification']);
    expect(p.first.localTime, DateTime(2026, 10, 21, 21, 30));
  });

  test('firm and strict ladders', () {
    expect(
      onDay(
        plan([
          input(g('a', {'preset': 'firm', 'time': '19:00'})),
        ]),
        today,
      ),
      ['19:00 notification', '19:30 sticky', '20:00 alarm'],
    );
    final strict = plan([
      input(g('a', {'preset': 'strict', 'time': '19:00'})),
    ]);
    expect(onDay(strict, today), ['19:00 notification', '19:30 sticky', '20:00 alarm', '20:30 strict_alarm']);
    final last = strict.where((r) => r.day == today).last.step;
    expect(last.dismiss, 'do_task');
    expect(last.minMinutes, 5);
  });

  test('an explicit ladder from the document', () {
    final goal = g('a', {
      'ladder': [
        {
          'at': '20:30',
          'level': 'strict_alarm',
          'dismiss': {
            'type': 'do_task',
            'minProgress': {'pages': 2},
          },
        },
        {'at': '19:00', 'level': 'notification'},
      ],
    });
    final p = plan([input(goal)]);
    expect(onDay(p, today), ['19:00 notification', '20:30 strict_alarm']);
    expect(p.firstWhere((r) => r.level == ReminderLevel.strictAlarm).step.minPages, 2);
  });

  test('steps already past today are skipped', () {
    final p = plan([
      input(g('a', {'preset': 'firm', 'time': '19:00'})),
    ], nowMinute: 19 * 60 + 15);
    expect(onDay(p, today), ['19:30 sticky', '20:00 alarm']);
    expect(onDay(p, today + 1), hasLength(3));
  });

  test('a goal done today gets no more reminders today', () {
    final p = plan([
      input(g('a', {'preset': 'firm', 'time': '19:00'}), todayDone: true),
    ]);
    expect(onDay(p, today), isEmpty);
    expect(onDay(p, today + 1), hasLength(3));
  });

  test('quiet hours win over the document', () {
    final p = plan([
      input(g('a', {'preset': 'strict', 'time': '22:00'})),
    ]);
    expect(onDay(p, today), ['22:00 notification', '22:30 sticky'], reason: '23:00 and later are quiet');
    final custom = plan([
      input(g('a', {'preset': 'gentle', 'time': '13:00'})),
    ], rules: const ReminderRules(quietStart: 12 * 60, quietEnd: 14 * 60));
    expect(custom, isEmpty);
  });

  test('at most 6 alarms a day across goals, earliest first', () {
    final goals = [
      for (var i = 0; i < 4; i++) input(g('g$i', {'preset': 'strict', 'time': '1${5 + i}:00'})),
    ];
    final p = plan(goals);
    final day = p.where((r) => r.day == today).toList();
    expect(day.where((r) => r.level.isAlarm), hasLength(6));
    expect(day.where((r) => !r.level.isAlarm), hasLength(8), reason: 'notifications are not limited');
    expect(day.where((r) => r.level.isAlarm).last.goalId, 'g2', reason: 'the latest alarms are dropped');
  });

  test('pause, disabled goals and schedule days', () {
    final paused = plan([
      input(g('a', {'preset': 'gentle', 'time': '19:00'})),
    ], rules: ReminderRules(pausedUntilDay: today + 1));
    expect(paused.map((r) => r.day).toSet().contains(today), false);
    expect(paused.map((r) => r.day).toSet().contains(today + 1), false);
    expect(paused, hasLength(5));

    expect(
      plan([
        input(g('a', {'preset': 'gentle'}), enabled: false),
      ]),
      isEmpty,
    );

    final mwf = plan([
      input(g('a', {'preset': 'gentle'}, days: ['mon', 'wed', 'fri'])),
    ]);
    expect(mwf.map((r) => DayClock.weekdayOf(r.day)).toSet(), {1, 3, 5});

    final override = plan([
      input(
        g(
          'a',
          {
            'preset': 'gentle',
            'days': ['sat'],
          },
          days: ['mon'],
        ),
      ),
    ]);
    expect(override.map((r) => DayClock.weekdayOf(r.day)).toSet(), {6});
  });

  test('ids are stable and unique', () {
    final a = plan([
      input(g('a', {'preset': 'strict'})),
      input(g('b', {'preset': 'strict'})),
    ]);
    final b = plan([
      input(g('a', {'preset': 'strict'})),
      input(g('b', {'preset': 'strict'})),
    ]);
    expect(a.map((r) => r.id).toList(), b.map((r) => r.id).toList());
    expect(a.map((r) => r.id).toSet(), hasLength(a.length));
    expect(a.every((r) => r.id & 0x40000000 == 0), true, reason: 'the snooze bit stays free');
  });

  group('strict alarm challenge', () {
    final start = at('2026-10-21T20:30:00').millisecondsSinceEpoch;

    test('do_task: 5 minutes of real watching', () {
      final events = [
        for (var i = 0; i <= 20; i++)
          ev(EventType.itemPosition, {
            'item': 'v',
            'sec': i * 15,
          }, at('2026-10-21T20:31:00').add(Duration(seconds: i * 15))),
      ];
      expect(
        challengeMet(
          dismiss: 'do_task',
          events: events,
          sinceUtcMs: start,
          todayComplete: false,
          minMinutes: 5,
          contentOpened: true,
        ),
        true,
      );
      expect(
        challengeMet(
          dismiss: 'do_task',
          events: events.take(10).toList(),
          sinceUtcMs: start,
          todayComplete: false,
          minMinutes: 5,
          contentOpened: true,
        ),
        false,
      );
    });

    test('do_task: pages count from the page at alarm time', () {
      bool met(List<int> pages) => challengeMet(
        dismiss: 'do_task',
        events: [
          for (final p in pages) ev(EventType.pageReached, {'page': p}, at('2026-10-21T20:35:00')),
        ],
        sinceUtcMs: start,
        todayComplete: false,
        minPages: 2,
        lastPageAtStart: 44,
        contentOpened: true,
      );
      expect(met([45]), false);
      expect(met([45, 46]), true);
    });

    test('events before the alarm do not count', () {
      expect(
        challengeMet(
          dismiss: 'do_task',
          events: [
            ev(EventType.itemDone, {'item': 'v', 'done': true}, at('2026-10-21T20:00:00')),
          ],
          sinceUtcMs: start,
          todayComplete: false,
          contentOpened: true,
        ),
        false,
      );
    });

    test('an undo is not progress', () {
      bool met(GoalEvent e) =>
          challengeMet(dismiss: 'do_task', events: [e], sinceUtcMs: start, todayComplete: false, contentOpened: true);
      final t = at('2026-10-21T20:40:00');
      expect(met(ev(EventType.check, {'checked': false}, t)), false);
      expect(met(ev(EventType.itemDone, {'item': 'v', 'done': false}, t)), false);
      expect(met(ev(EventType.countDelta, {'delta': -1}, t)), false);
      expect(met(ev(EventType.check, {'checked': true}, t)), true);
    });

    test('start_task needs the content opened; today complete always ends it', () {
      expect(
        challengeMet(
          dismiss: 'start_task',
          events: const [],
          sinceUtcMs: start,
          todayComplete: false,
          contentOpened: false,
        ),
        false,
      );
      expect(
        challengeMet(
          dismiss: 'start_task',
          events: const [],
          sinceUtcMs: start,
          todayComplete: false,
          contentOpened: true,
        ),
        true,
      );
      expect(
        challengeMet(
          dismiss: 'do_task',
          events: const [],
          sinceUtcMs: start,
          todayComplete: true,
          contentOpened: false,
        ),
        true,
      );
    });
  });
}
