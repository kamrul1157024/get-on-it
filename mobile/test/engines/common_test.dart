import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/core/time/day_clock.dart';
import 'package:getonit/engines/habits.dart';

import '../support/harness.dart';

void main() {
  const check = CheckEngine();

  GoalEvent checkOn(String date) => ev(EventType.check, {'checked': true}, at('${date}T12:00:00'));

  group('streak', () {
    // 2026-10-19 is a Monday.
    final monWedFri = goal(
      'habit@1',
      {'mode': 'check'},
      extra: {
        'schedule': {
          'days': ['mon', 'wed', 'fri'],
        },
        'startDate': '2026-10-01',
      },
    );

    test('rest days do not break the streak', () {
      final s = check.computeState(
        ctx(monWedFri, [checkOn('2026-10-16'), checkOn('2026-10-19')], at('2026-10-20T09:00:00')),
      );
      expect(s['streak'], 2);
    });

    test('today in progress does not break the streak', () {
      final s = check.computeState(ctx(monWedFri, [checkOn('2026-10-19')], at('2026-10-21T09:00:00')));
      expect(s['todayComplete'], false);
      expect(s['streak'], 1);
    });

    test('a missed scheduled day breaks the streak', () {
      final s = check.computeState(
        ctx(monWedFri, [checkOn('2026-10-14'), checkOn('2026-10-19')], at('2026-10-20T09:00:00')),
      );
      expect(s['streak'], 1, reason: 'Fri 16 Oct was missed');
    });

    test('a skipped day does not break the streak', () {
      final s = check.computeState(
        ctx(monWedFri, [
          checkOn('2026-10-14'),
          ev(EventType.daySkipped, {'date': '2026-10-16', 'reason': 'sick'}, at('2026-10-16T20:00:00')),
          checkOn('2026-10-19'),
        ], at('2026-10-20T09:00:00')),
      );
      expect(s['streak'], 2);
    });
  });

  group('day boundary', () {
    final daily = goal('habit@1', {'mode': 'check'});

    test('with "my day starts at 04:00", 01:00 counts for the day before', () {
      final late = ev(EventType.check, {'checked': true}, at('2026-10-21T01:00:00'));
      final s = check.computeState(ctx(daily, [late], at('2026-10-21T02:00:00'), dayStartHour: 4));
      expect(s['todayComplete'], true, reason: 'it is still 20 Oct in the user\'s day');
      final next = check.computeState(ctx(daily, [late], at('2026-10-21T05:00:00'), dayStartHour: 4));
      expect(next['todayComplete'], false);
      expect(next['streak'], 1);
    });

    test('events keep the offset of their time zone', () {
      // 23:30 in UTC+6 on 21 Oct is 17:30 UTC. After flying to UTC−5 it still
      // belongs to 21 Oct.
      final e = ev(EventType.check, {'checked': true}, at('2026-10-21T17:30:00'), offset: 360);
      const clock = DayClock();
      expect(DayClock.isoDate(clock.dayOf(e.utcMs, e.offsetMinutes)), '2026-10-21');
      final s = check.computeState(ctx(daily, [e], at('2026-10-21T20:00:00'), offset: -300));
      expect(s['todayComplete'], true);
    });
  });

  group('pace', () {
    final g = goal(
      'habit@1',
      {
        'mode': 'checklist',
        'resets': 'never',
        'steps': [
          for (var i = 0; i < 10; i++) {'id': 's$i', 'title': 'Step $i'},
        ],
      },
      extra: {'startDate': '2026-10-01', 'deadline': '2026-10-10'},
    );
    const engine = ChecklistEngine();

    test('behind when progress trails the linear target by more than a day', () {
      final s = engine.computeState(ctx(g, const [], at('2026-10-05T09:00:00')));
      expect((s['pace'] as Map)['status'], 'behind');
      expect((s['pace'] as Map)['label'], '4 days behind');
      expect(s['deadlineLabel'], '5 days');
    });

    test('on track within one day of work', () {
      final events = [
        for (var i = 0; i < 4; i++)
          ev(EventType.stepDone, {'step': 's$i', 'done': true}, at('2026-10-0${i + 1}T09:00:00')),
      ];
      final s = engine.computeState(ctx(g, events, at('2026-10-05T09:00:00')));
      expect((s['pace'] as Map)['status'], 'on_track');
    });
  });

  test('week dots and heatmap', () {
    final s = check.computeState(
      ctx(goal('habit@1', {'mode': 'check'}, extra: {'startDate': '2026-10-01'}), [
        checkOn('2026-10-19'),
      ], at('2026-10-21T09:00:00')),
    );
    final week = (s['week'] as List).cast<Map>();
    expect(week.map((d) => d['s']).toList(), ['done', '', 'today', '', '', '', '']);
    final heat = (s['heatmap'] as List).cast<Map>();
    expect(heat.length, 84);
    expect(heat.firstWhere((c) => c['date'] == '2026-10-19')['level'], 4);
    expect(heat.firstWhere((c) => c['date'] == '2026-10-25')['level'], -1, reason: 'future days are blank');
  });
}
