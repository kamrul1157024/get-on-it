import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/engines/habits.dart';

import '../support/harness.dart';

void main() {
  test('count sums deltas for today', () {
    final g = goal('habit@1', {'mode': 'count', 'unit': 'glasses', 'target': 8});
    final s = const CountEngine().computeState(
      ctx(g, [
        ev(EventType.countDelta, {'delta': 1}, at('2026-10-20T10:00:00')),
        for (var i = 0; i < 6; i++) ev(EventType.countDelta, {'delta': 1}, at('2026-10-21T0$i:30:00')),
        ev(EventType.countDelta, {'delta': -1}, at('2026-10-21T09:00:00')),
      ], at('2026-10-21T12:00:00')),
    );
    expect(s['count'], 5);
    expect(s['label'], '5 / 8 glasses');
    expect(s['progress'], 5 / 8);
    expect(s['isCount'], true);
  });

  test('weekly count adds up since Monday', () {
    final g = goal('habit@1', {'mode': 'count', 'unit': 'runs', 'target': 3, 'period': 'week'});
    final s = const CountEngine().computeState(
      ctx(g, [
        ev(EventType.countDelta, {'delta': 1}, at('2026-10-18T10:00:00')), // Sunday, last week
        ev(EventType.countDelta, {'delta': 1}, at('2026-10-19T10:00:00')),
        ev(EventType.countDelta, {'delta': 1}, at('2026-10-21T10:00:00')),
      ], at('2026-10-21T12:00:00')),
    );
    expect(s['count'], 2);
    expect(s['periodLabel'], 'this week');
  });

  test('avoid habit: a check is a slip', () {
    final g = goal('habit@1', {'mode': 'check', 'avoid': true}, extra: {'startDate': '2026-10-15'});
    final clean = const CheckEngine().computeState(ctx(g, const [], at('2026-10-21T12:00:00')));
    expect(clean['todayComplete'], true);
    expect(clean['cleanDays'], 6);
    final slipped = const CheckEngine().computeState(
      ctx(g, [
        ev(EventType.check, {'checked': true}, at('2026-10-21T10:00:00')),
      ], at('2026-10-21T12:00:00')),
    );
    expect(slipped['todayComplete'], false);
    expect(slipped['buttonLabel'], 'Undo slip');
  });

  test('daily checklist resets each day', () {
    final g = goal('habit@1', {
      'mode': 'checklist',
      'steps': [
        {'id': 'a', 'title': 'Stretch'},
        {'id': 'b', 'title': 'Journal'},
      ],
    });
    final events = [
      ev(EventType.stepDone, {'step': 'a', 'done': true}, at('2026-10-20T07:00:00')),
      ev(EventType.stepDone, {'step': 'b', 'done': true}, at('2026-10-20T07:10:00')),
      ev(EventType.stepDone, {'step': 'a', 'done': true}, at('2026-10-21T07:00:00')),
    ];
    final s = const ChecklistEngine().computeState(ctx(g, events, at('2026-10-21T12:00:00')));
    expect(s['label'], '1 / 2');
    expect(s['todayComplete'], false);
    expect(s['streak'], 1);
  });

  group('a different exercise on different days', () {
    final g = goal(
      'habit@1',
      {
        'mode': 'checklist',
        'steps': [
          {
            'id': 'push-ups',
            'title': 'Push-ups',
            'detail': '3 × 15',
            'days': ['mon'],
          },
          {
            'id': 'squats',
            'title': 'Squats',
            'detail': '3 × 20',
            'days': ['wed'],
          },
          {
            'id': 'plank',
            'title': 'Plank',
            'detail': '3 × 1 min',
            'days': ['fri'],
          },
          {
            'id': 'run',
            'title': 'Run',
            'detail': '20 min',
            'days': ['sat'],
          },
        ],
      },
      extra: {'startDate': '2026-10-19'},
    );

    test('today shows only today\'s exercise, with its detail', () {
      // 2026-10-21 is a Wednesday.
      final s = const ChecklistEngine().computeState(ctx(g, const [], at('2026-10-21T12:00:00')));
      expect(s['steps'], [
        {'id': 'squats', 'title': 'Squats', 'done': false, 'detail': '3 × 20'},
      ]);
      expect(s['hasStepsToday'], true);
      expect(s['restDay'], false);
      expect(s['label'], '0 / 1');
    });

    test('a day without an exercise is a rest day and not scheduled', () {
      expect(g.scheduleDays, {1, 3, 5, 6});
      // 2026-10-22 is a Thursday.
      final s = const ChecklistEngine().computeState(ctx(g, const [], at('2026-10-22T12:00:00')));
      expect(s['steps'], isEmpty);
      expect(s['restDay'], true);
      expect(s['hasStepsToday'], false);
      expect(s['todayScheduled'], false);
    });

    test('the streak counts exercise days and skips rest days', () {
      final s = const ChecklistEngine().computeState(
        ctx(g, [
          ev(EventType.stepDone, {'step': 'push-ups', 'done': true}, at('2026-10-19T18:00:00')),
          ev(EventType.stepDone, {'step': 'squats', 'done': true}, at('2026-10-21T18:00:00')),
          ev(EventType.stepDone, {'step': 'plank', 'done': true}, at('2026-10-23T18:00:00')),
        ], at('2026-10-23T20:00:00')),
      );
      expect(s['todayComplete'], true);
      expect(s['streak'], 3);
    });

    test('a schedule in the plan still wins over the steps\' days', () {
      final g2 = goal(
        'habit@1',
        {
          'mode': 'checklist',
          'steps': [
            {
              'id': 'run',
              'title': 'Run',
              'days': ['sat'],
            },
          ],
        },
        extra: {
          'schedule': {
            'days': ['sat', 'sun'],
          },
        },
      );
      expect(g2.scheduleDays, {6, 7});
    });
  });
}
