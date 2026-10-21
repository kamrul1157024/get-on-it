import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/engines/page_range.dart';

import '../support/harness.dart';

void main() {
  const engine = PageRangeEngine();
  final book = goal('book@1', {
    'book': {'title': 'Atomic Habits', 'author': 'James Clear'},
    'source': {'kind': 'physical'},
    'pages': {'start': 1, 'end': 320, 'perDay': 2},
  });

  group('the worked example from the design discussion', () {
    final events = [
      ev(EventType.pageReached, {'page': 42}, at('2026-10-20T21:10:00')),
      ev(EventType.pageReached, {'page': 44}, at('2026-10-20T21:14:00')),
      ev(EventType.pageReached, {'page': 45}, at('2026-10-21T19:40:00')),
    ];

    test("today's pages are fixed at the start of the day", () {
      final s = engine.computeState(ctx(book, events, at('2026-10-21T19:41:00')));
      final today = s['today'] as Map;
      expect(s['lastPage'], 45);
      expect(today['startPage'], 45);
      expect(today['endPage'], 46);
      expect(today['label'], 'p. 45–46');
      expect(s['todayComplete'], false);
      expect(s['progress'], closeTo(45 / 320, 1e-9));
      expect(s['progressLabel'], 'Page 45 of 320');
    });

    test('reaching the end page completes today and extends the streak', () {
      final more = [
        ...events,
        ev(EventType.pageReached, {'page': 46}, at('2026-10-21T19:43:00')),
      ];
      final s = engine.computeState(ctx(book, more, at('2026-10-21T19:44:00')));
      expect((s['today'] as Map)['label'], 'p. 45–46', reason: 'the target does not move after reading');
      expect(s['todayComplete'], true);
      // 20 Oct: 0 → 44 met its 2-page target; 21 Oct: 44 → 46 met it.
      expect(s['streak'], 2);
    });
  });

  test('a deadline sets the pace and wins over perDay', () {
    final g = goal(
      'book@1',
      {
        'book': {'title': 'B'},
        'source': {'kind': 'physical'},
        'pages': {'start': 1, 'end': 100, 'perDay': 2},
      },
      extra: {'startDate': '2026-10-01', 'deadline': '2026-10-10'},
    );
    // 10 days left including today, 100 pages → 10 per day.
    final s = engine.computeState(ctx(g, const [], at('2026-10-01T08:00:00')));
    expect(s['perDay'], 10);
    expect((s['today'] as Map)['label'], 'p. 1–10');
  });

  test('a local PDF without a linked file needs a file', () {
    final g = goal('book@1', {
      'book': {'title': 'B'},
      'source': {'kind': 'local_file'},
      'pages': {'start': 1, 'end': 10},
    });
    expect(engine.computeState(ctx(g, const [], at('2026-10-01T08:00:00')))['needsFile'], true);
    final linked = engine.computeState(ctx(g, const [], at('2026-10-01T08:00:00'), files: {'g': '/tmp/b.pdf'}));
    expect(linked['needsFile'], false);
    expect(linked['canOpen'], true);
  });

  test('finished book', () {
    final s = engine.computeState(
      ctx(book, [
        ev(EventType.pageReached, {'page': 320}, at('2026-10-21T10:00:00')),
      ], at('2026-10-22T10:00:00')),
    );
    expect(s['isComplete'], true);
    expect((s['today'] as Map)['label'], 'Finished');
    expect(s['finishLabel'], 'Finished');
  });
}
