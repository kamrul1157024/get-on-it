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
}
