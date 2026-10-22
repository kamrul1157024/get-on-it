import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/core/events/goal_event.dart';
import 'package:getonit/engines/video_series.dart';

import '../support/harness.dart';

void main() {
  const engine = VideoSeriesEngine();
  final course = goal('course@1', {
    'dailyTargetMinutes': 30,
    'items': [
      {'id': 'lec-07', 'kind': 'video', 'title': 'Lecture 7', 'videoId': 'aaaaaaa', 'durationSec': 4800},
      {'id': 'lec-08', 'kind': 'video', 'title': 'Lecture 8', 'videoId': 'bbbbbbb', 'durationSec': 4800},
      {'id': 'pset-1', 'kind': 'task', 'title': 'Problem Set 1'},
    ],
  });

  Map<String, Object?> item(Map<String, Object?> s, String id) =>
      (s['items'] as List).cast<Map<String, Object?>>().firstWhere((i) => i['id'] == id);

  test('resume uses the newest position; progress uses the highest', () {
    final s = engine.computeState(
      ctx(course, [
        ev(EventType.itemPosition, {'item': 'lec-07', 'sec': 600}, at('2026-10-21T19:05:00')),
        ev(EventType.itemPosition, {'item': 'lec-07', 'sec': 2052}, at('2026-10-21T19:30:00')),
        ev(EventType.itemPosition, {'item': 'lec-07', 'sec': 300}, at('2026-10-21T20:10:00')),
      ], at('2026-10-21T20:11:00')),
    );
    final lec = item(s, 'lec-07');
    expect(lec['positionSec'], 300);
    expect(lec['positionLabel'], '5 min');
    expect(lec['resumeLabel'], 'Continue from 5 min');
    expect(lec['resumeText'], 'Stopped at 5 min · 1 h 15 min left');
    expect(lec['watched'], closeTo(2052 / 4800, 1e-9));
    expect(lec['done'], false);
    expect((s['next'] as Map)['id'], 'lec-07');
  });

  test('90% watched marks a video done, and the next item moves on', () {
    final s = engine.computeState(
      ctx(course, [
        ev(EventType.itemPosition, {'item': 'lec-07', 'sec': 4320}, at('2026-10-21T20:00:00')),
      ], at('2026-10-21T20:01:00')),
    );
    expect(item(s, 'lec-07')['done'], true);
    expect((s['next'] as Map)['id'], 'lec-08');
    expect(s['progressLabel'], '1 of 2 videos');
    expect(s['todayComplete'], true, reason: 'finishing an item completes the day');
  });

  test('a seek forward does not count as watch time', () {
    final s = engine.computeState(
      ctx(course, [
        ev(EventType.itemPosition, {'item': 'lec-08', 'sec': 0}, at('2026-10-21T19:00:00')),
        ev(EventType.itemPosition, {'item': 'lec-08', 'sec': 3000}, at('2026-10-21T19:00:20')),
      ], at('2026-10-21T19:01:00')),
    );
    expect(s['todayWatchedLabel'], '0 min');
    expect(s['todayComplete'], false);
  });

  test('30 minutes of real watching completes the day', () {
    final events = [
      for (var i = 0; i <= 120; i++)
        ev(EventType.itemPosition, {
          'item': 'lec-08',
          'sec': i * 15,
        }, at('2026-10-21T19:00:00').add(Duration(seconds: i * 15))),
    ];
    final s = engine.computeState(ctx(course, events, at('2026-10-21T19:31:00')));
    expect(s['todayWatchedLabel'], '30 min');
    expect(s['todayComplete'], true);
  });

  test('mark done and undo', () {
    final done = ev(EventType.itemDone, {'item': 'pset-1', 'done': true}, at('2026-10-21T10:00:00'));
    expect(item(engine.computeState(ctx(course, [done], at('2026-10-21T11:00:00'))), 'pset-1')['done'], true);
    final undo = ev(EventType.itemDone, {'item': 'pset-1', 'done': false}, at('2026-10-21T10:05:00'));
    expect(item(engine.computeState(ctx(course, [done, undo], at('2026-10-21T11:00:00'))), 'pset-1')['done'], false);
  });

  test('events for removed items are kept but ignored', () {
    final s = engine.computeState(
      ctx(course, [
        ev(EventType.itemDone, {'item': 'lec-99', 'done': true}, at('2026-10-21T10:00:00')),
      ], at('2026-10-21T11:00:00')),
    );
    expect(s['doneCount'], 0);
  });

  test('summary for the import preview', () {
    expect(engine.summary(course), '2 videos · 1 task · 2 h 40 min');
  });
}
