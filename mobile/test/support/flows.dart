import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:getonit/core/time/clock_format.dart';
import 'package:getonit/features/player/video_backend.dart';
import 'package:getonit/features/nudges/wasted_time.dart';
import 'package:getonit/features/reminders/planner.dart';
import 'package:getonit/features/reminders/reminders_controller.dart';

import 'app_harness.dart';

/// User flows shared by the host widget tests (test/app_flow_test.dart) and
/// the on-device e2e tests (integration_test/app_test.dart).

Future<String> sampleText(String name) async {
  try {
    return await rootBundle.loadString('assets/samples/$name');
  } catch (_) {
    return File('assets/samples/$name').readAsStringSync();
  }
}

/// The sample course with embedding allowed, for tests of the in-app player.
/// (The real CS229 videos do not allow embedding.)
Future<String> embeddableCourse() async {
  final doc = (jsonDecode(await sampleText('course-cs229.getonit.json')) as Map).cast<String, Object?>();
  for (final item in ((doc['data'] as Map)['items'] as List).cast<Map>()) {
    item.remove('embeddable');
  }
  return jsonEncode(doc);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 20),
  );
}

/// Pumps until [f] finds something. Checking a plan reads the database and
/// draws the preview; on a slow emulator that outlasts one settle, which only
/// waits for frames, not for futures.
Future<void> waitFor(WidgetTester tester, Finder f, {Duration timeout = const Duration(seconds: 15)}) async {
  final live = tester.binding is LiveTestWidgetsFlutterBinding;
  final end = DateTime.now().add(timeout);
  var fakeElapsed = Duration.zero;
  while (f.evaluate().isEmpty) {
    if (live ? DateTime.now().isAfter(end) : fakeElapsed > timeout) break;
    await tester.pump(const Duration(milliseconds: 100));
    if (live) await Future<void>.delayed(const Duration(milliseconds: 100));
    fakeElapsed += const Duration(milliseconds: 100);
  }
  await settle(tester);
}

/// Scrolls the first scrollable until [f] is built, for lazy lists.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  await tester.scrollUntilVisible(f, 200, scrollable: scrollable.first, maxScrolls: 30);
}

Future<void> tapText(WidgetTester tester, String text) async {
  await _reveal(tester, find.text(text));
  final f = find.text(text).first;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await settle(tester);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await _reveal(tester, find.byKey(ValueKey(key)));
  final f = find.byKey(ValueKey(key)).first;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await settle(tester);
}

/// Opens the import screen from the Today screen, pastes [json], checks it.
Future<void> pastePlan(WidgetTester tester, String json) async {
  final empty = find.byKey(const ValueKey('empty-import'));
  if (empty.evaluate().isNotEmpty) {
    await tapKey(tester, 'empty-import');
  } else {
    await tapKey(tester, 'fab-import');
  }
  await tester.enterText(find.byKey(const ValueKey('import-text')), json);
  await checkPlan(tester);
}

/// Taps "Check" and waits for its verdict: the errors or the import button.
Future<void> checkPlan(WidgetTester tester) async {
  await tapKey(tester, 'import-check');
  await waitFor(
    tester,
    find.byWidgetPredicate(
      (w) => w.key == const ValueKey('import-errors') || w.key == const ValueKey('import-confirm'),
    ),
  );
}

Future<void> importPlan(WidgetTester tester, String json) async {
  await pastePlan(tester, json);
  expect(find.byKey(const ValueKey('import-errors')), findsNothing);
  await tapKey(tester, 'import-confirm');
}

Future<void> goBack(WidgetTester tester) async {
  await tester.pageBack();
  await settle(tester);
}

/// Course: import → preview → Today tile → goal screen → mark done → state.
Future<void> courseFlow(WidgetTester tester) async {
  final json = await sampleText('course-cs229.getonit.json');
  await pastePlan(tester, json);
  expect(find.textContaining('21 videos · 1 task'), findsOneWidget);
  expect(find.text('New goal'), findsOneWidget);
  await tapKey(tester, 'import-confirm');

  expect(find.text('Stanford CS229: Machine Learning'), findsOneWidget);
  expect(find.text('Next: Lecture 1: Introduction'), findsOneWidget);
  await tapText(tester, 'Stanford CS229: Machine Learning');

  expect(find.text('0 of 21 videos'), findsWidgets);
  await tapText(tester, 'Mark done');
  expect(find.text('1 of 21 videos'), findsWidgets);
  expect(find.text('Lecture 2: Linear Regression and Gradient Descent'), findsWidgets);
  await goBack(tester);
  expect(find.text('Next: Lecture 2: Linear Regression and Gradient Descent'), findsOneWidget);
}

/// Re-import with one more lecture: the diff shows it and progress stays.
Future<void> reimportFlow(WidgetTester tester) async {
  final doc = (jsonDecode(await sampleText('course-cs229.getonit.json')) as Map).cast<String, Object?>();
  ((doc['data'] as Map)['items'] as List).add({
    'id': 'lec-bonus',
    'kind': 'video',
    'title': 'Bonus lecture',
    'videoId': 'jGwO_UgTS7I',
    'durationSec': 600,
  });
  await pastePlan(tester, jsonEncode(doc));
  expect(find.text('1 added. Your progress stays.'), findsOneWidget);
  expect(find.text('+ Bonus lecture'), findsOneWidget);
  expect(find.text('Update'), findsOneWidget);
  await tapKey(tester, 'import-confirm');
  await tapText(tester, 'Stanford CS229: Machine Learning');
  expect(find.text('1 of 22 videos'), findsWidgets);
  await goBack(tester);
}

/// Physical book: log a page by hand; today completes.
Future<void> bookFlow(WidgetTester tester) async {
  await importPlan(tester, await sampleText('book-atomic-habits.getonit.json'));
  await tapText(tester, 'Read Atomic Habits · Page 0 of 320');
  expect(find.text('p. 1–2'), findsWidgets);
  await tester.enterText(find.byKey(const ValueKey('number:page-reached')), '2');
  await tapText(tester, 'Save');
  expect(find.text('Page 2 of 320 · Finish ≈ ${_finishDate()}'), findsOneWidget);
  expect(find.text('✓ Done today'), findsOneWidget);
  expect(find.text('Mark today done'), findsNothing);
  await goBack(tester);
}

String _finishDate() {
  // Remaining after today: 318 pages at 2 per day = 159 days, from tomorrow.
  final d = DateTime.now().add(const Duration(days: 159));
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]}';
}

/// Sample habits: the counter on the Today tile works without opening the goal.
Future<void> habitCounterFlow(WidgetTester tester) async {
  await tapKey(tester, 'empty-samples');
  expect(find.text('Drink water'), findsOneWidget);
  final water = find.byKey(const ValueKey('goal-tile:water'));
  await tester.ensureVisible(water);
  await tester.pumpAndSettle();
  final plus = find.descendant(of: water, matching: find.byKey(const ValueKey('counter:increment')));
  for (var i = 0; i < 3; i++) {
    await tester.tap(plus);
    await settle(tester);
  }
  expect(find.descendant(of: water, matching: find.text('3 / 8 glasses')), findsOneWidget);
  final minus = find.descendant(of: water, matching: find.byKey(const ValueKey('counter:decrement')));
  await tester.tap(minus);
  await settle(tester);
  expect(find.descendant(of: water, matching: find.text('2 / 8 glasses')), findsOneWidget);

  final meditate = find.byKey(const ValueKey('goal-tile:meditate'));
  await tester.ensureVisible(meditate);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: meditate, matching: find.text('Mark done')));
  await settle(tester);
  expect(find.descendant(of: meditate, matching: find.text('Done today')), findsOneWidget);
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
  await tester.pumpAndSettle();
  expect(find.text('1 of 4 done today'), findsOneWidget);
}

/// A broken plan shows errors with paths.
Future<void> invalidPlanFlow(WidgetTester tester) async {
  await pastePlan(
    tester,
    '{"kind":"goal","schemaVersion":"1.0","id":"x","template":"course@1","title":"T","data":{"items":[]}}',
  );
  expect(find.byKey(const ValueKey('import-errors')), findsOneWidget);
  expect(find.textContaining('data.items'), findsOneWidget);
  expect(find.byKey(const ValueKey('import-confirm')), findsNothing);
  await goBack(tester);
}

/// A template-only bundle around [screen], for preview checks.
String _bundle(Map<String, Object?> screen) => jsonEncode({
  'kind': 'bundle',
  'schemaVersion': '1.0',
  'documents': [
    {
      'kind': 'template',
      'id': 'probe',
      'version': '1.0.0',
      'engine': 'count',
      'surfaces': {'screen': screen},
    },
    {
      'kind': 'goal',
      'id': 'probe-goal',
      'template': 'probe@1',
      'title': 'Probe',
      'data': {'unit': 'reps', 'target': 3},
    },
  ],
});

/// The import preview draws the real screen and both widgets, blocks a plan
/// whose layout fails, and copies a fix prompt for it and for warnings.
Future<void> previewFlow(WidgetTester tester) async {
  await pastePlan(tester, await rootBundle.loadString('assets/prompt/custom_example.json'));
  await settle(tester);
  final preview = find.byKey(const ValueKey('surface-preview:spanish-practice:screen'));
  expect(find.descendant(of: preview, matching: find.text('Start a session')), findsOneWidget);
  expect(find.byKey(const ValueKey('fix-with-ai')), findsNothing);
  await tester.tap(find.text('Small'));
  await settle(tester);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('surface-preview:spanish-practice:tile')),
      matching: find.text('0 / 4 sessions'),
    ),
    findsOneWidget,
  );
  expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-confirm'))).onPressed, isNotNull);
  await goBack(tester);

  // A heatmap inside a grid cannot be measured: the layout fails. Flutter
  // reports each failure; count them instead of failing the test on them.
  final report = FlutterError.onError;
  var layoutErrors = 0;
  FlutterError.onError = (_) => layoutErrors++;
  try {
    await pastePlan(
      tester,
      _bundle({
        'type': 'grid',
        'children': [
          {'type': 'heatmap', 'cells': '{{state.heatmap}}'},
        ],
      }),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('surface-broken:probe-goal:screen')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-confirm'))).onPressed, isNull);
    expect(find.text('Fix with AI'), findsOneWidget);
    await tapKey(tester, 'fix-copy');
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    expect(copied, contains('screen: the goal screen failed to lay out'));
    expect(copied, contains('"id":"probe"'));
    await goBack(tester);
  } finally {
    FlutterError.onError = report;
  }
  expect(layoutErrors, greaterThan(0));

  // A wrong binding is a warning: import still works, fixing is optional.
  await pastePlan(tester, _bundle({'type': 'text', 'value': '{{state.nope}}'}));
  await settle(tester);
  expect(find.textContaining('the "count" engine has no "nope"'), findsWidgets);
  expect(find.text('Fix the warnings with AI (optional)'), findsOneWidget);
  expect(tester.widget<FilledButton>(find.byKey(const ValueKey('import-confirm'))).onPressed, isNotNull);
  await goBack(tester);
}

/// "Time lost": without usage access, a row that leads to it; with it, the
/// first thing on the Today screen, compact with today, and one tap opens
/// today, this month and this year with what that time could have been. An
/// app can be taken off the list. The nudge settings carry the goals' units
/// and the exclusions to the phone.
Future<void> timeLostFlow(WidgetTester tester, Fakes fakes) async {
  final b = fakes.nudges;
  b.usage = const {
    LostPeriod.today: [
      AppUsage('com.instagram.android', 'Instagram', 'social', 95),
      AppUsage('com.google.android.youtube', 'YouTube', 'video', 50),
      AppUsage('com.king.candycrush', 'Candy Crush', 'game', 10),
      AppUsage('com.example.news', 'News', 'news', 5),
    ],
    LostPeriod.month: [
      AppUsage('com.instagram.android', 'Instagram', 'social', 1800),
      AppUsage('com.google.android.youtube', 'YouTube', 'video', 1200),
    ],
    LostPeriod.year: [
      AppUsage('com.instagram.android', 'Instagram', 'social', 3600),
      AppUsage('com.google.android.youtube', 'YouTube', 'video', 2160),
    ],
  };
  await tapKey(tester, 'empty-samples');
  // No usage access: one row that leads to it.
  expect(find.byKey(const ValueKey('time-lost')), findsNothing);
  await tapKey(tester, 'time-lost-setup');
  expect(find.byKey(const ValueKey('usage-help')), findsOneWidget);
  await tapKey(tester, 'usage-open-settings');
  await tapKey(tester, 'usage-close');
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await waitFor(tester, find.byKey(const ValueKey('time-lost')));

  // Compact: today only.
  expect(find.byKey(const ValueKey('time-lost-setup')), findsNothing);
  expect(find.text('2 h 40 min'), findsOneWidget);
  expect(find.byKey(const ValueKey('time-lost-periods')), findsNothing);
  // The course is first: 160 min is 2 lectures of 75 min; the book 80 pages.
  expect(
    find.text(
      'On social, video, game and news apps. '
      'That could have been 2 Stanford CS229 lectures, or 80 pages of Atomic Habits.',
    ),
    findsOneWidget,
  );
  final units = (b.last['equivalents'] as List).cast<Map>();
  expect(units.map((u) => u['plural']), ['Stanford CS229 lectures', 'pages of Atomic Habits']);

  // One tap opens the periods; the year counts whole courses.
  await tapKey(tester, 'time-lost-toggle');
  expect(find.text('1 h 35 min scrolling'), findsOneWidget);
  expect(find.byKey(const ValueKey('time-lost-app:com.example.news')), findsNothing, reason: 'top three only');
  await tester.tap(find.text('This year'));
  await settle(tester);
  expect(find.text('96 h'), findsOneWidget);
  final courseHours = (units.first['wholeMinutes'] as num) / 60;
  final times = (96 * 60 / (courseHours * 60)).floor();
  expect(find.textContaining('or the whole course $times times'), findsOneWidget);
  expect(
    find.text(
      'Counted by Android, including time before you installed Get On It. For older weeks it can be a little lower than your real use.',
    ),
    findsOneWidget,
  );
  await tester.tap(find.text('This month'));
  await settle(tester);
  expect(find.text('50 h'), findsOneWidget);

  // Take Instagram off the list, then undo.
  await tapKey(tester, 'time-lost-exclude:com.instagram.android');
  await waitFor(tester, find.text('20 h'));
  expect(b.lastExcluded, ['com.instagram.android']);
  await waitFor(tester, find.text('Undo'));
  expect(b.last['excluded'], ['com.instagram.android']);
  await tester.tap(find.text('Undo'));
  await waitFor(tester, find.text('50 h'));
  expect(b.lastExcluded, isEmpty);
}

// ---------------------------------------------------------------------------
// Every remaining interaction. `fakes` is the harness's record of what the app
// did outside itself (player, external links).
// ---------------------------------------------------------------------------

Finder _inTile(String goalId, Finder f) => find.descendant(of: find.byKey(ValueKey('goal-tile:$goalId')), matching: f);

Future<void> _tapIn(WidgetTester tester, String goalId, Finder f) async {
  final target = _inTile(goalId, f).first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await settle(tester);
}

/// Player: Resume from Today, positions are saved every 15 s, on pause and
/// on close; YouTube button; Resume continues where the user stopped; Mark
/// done in the player moves the course on.
Future<void> playerFlow(WidgetTester tester, Fakes fakes) async {
  await importPlan(tester, await embeddableCourse());
  await _tapIn(tester, 'stanford-cs229', find.text('▶ Start'));
  expect(find.text('Lecture 1: Introduction'), findsOneWidget, reason: 'player title');
  expect(fakes.video.videoId, 'jGwO_UgTS7I');
  expect(fakes.video.startSec, 0);

  fakes.video.play(60.0); // first position is saved at once
  fakes.video.play(75.0); // within 15 s: not saved yet
  fakes.video.pause(); // pause saves 75
  await settle(tester);

  await tapKey(tester, 'player-youtube');
  expect(fakes.launched.last.toString(), 'https://www.youtube.com/watch?v=jGwO_UgTS7I&t=75s');

  fakes.video.play(120.0);
  await goBack(tester); // closing saves 120
  expect(fakes.video.disposed, true);
  expect(_inTile('stanford-cs229', find.text('▶ Continue from 2 min')), findsOneWidget);

  await _tapIn(tester, 'stanford-cs229', find.text('▶ Continue from 2 min'));
  expect(fakes.video.startSec, 120);

  // The owner does not allow the video in other apps: explain and offer YouTube.
  fakes.video.fail(VideoProblem.notEmbeddable);
  await settle(tester);
  expect(find.byKey(const ValueKey('player-problem:notEmbeddable')), findsOneWidget);
  expect(find.byKey(ValueKey('fake-player:${fakes.video.videoId}')), findsNothing);
  await tapKey(tester, 'player-problem-youtube');
  expect(fakes.launched.last.toString(), 'https://www.youtube.com/watch?v=jGwO_UgTS7I&t=120s');
  await tapKey(tester, 'player-mark-done');
  expect(find.text('Done'), findsOneWidget);
  await goBack(tester);
  expect(find.text('Next: Lecture 2: Linear Regression and Gradient Descent'), findsOneWidget);
}

/// Course screen: open a lecture from the list, toggle a task, "Open task"
/// for a task that is next, and delete the goal with cancel and confirm.
Future<void> courseScreenFlow(WidgetTester tester, Fakes fakes) async {
  await tapKey(tester, 'empty-samples');
  await tapText(tester, 'Stanford CS229: Machine Learning');

  // The owner does not allow these videos in other apps: they open on YouTube.
  expect(find.text('▶ Watch on YouTube'), findsOneWidget);
  await tapText(tester, 'Lecture 3: Locally Weighted & Logistic Regression');
  expect(fakes.videos, isEmpty, reason: 'the in-app player does not open');
  expect(fakes.launched.last.toString(), 'https://www.youtube.com/watch?v=het9HFqo1TQ&t=0s');
  expect(find.textContaining('This video plays on YouTube'), findsOneWidget);
  await tapText(tester, '▶ Watch on YouTube');
  expect(fakes.launched.last.toString(), 'https://www.youtube.com/watch?v=jGwO_UgTS7I&t=0s');

  final task = find.byKey(const ValueKey('check:Problem Set 1'));
  final taskChecked = find.descendant(of: task, matching: find.byIcon(Icons.check));
  expect(taskChecked, findsNothing);
  await tapKey(tester, 'check:Problem Set 1');
  expect(taskChecked, findsOneWidget);
  await tapKey(tester, 'check:Problem Set 1');
  expect(taskChecked, findsNothing);

  // Finish lectures 1–4 so the task is next.
  for (var i = 0; i < 4; i++) {
    await tapText(tester, 'Mark done');
  }
  expect(find.text('4 of 21 videos'), findsWidgets);
  await tapText(tester, 'Open task');
  expect(fakes.launched.last.toString(), 'https://cs229.stanford.edu/');
  await tapText(tester, 'Mark done');
  expect(find.text('Lecture 5: GDA & Naive Bayes'), findsWidgets);

  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Delete goal');
  await tapText(tester, 'Cancel');
  expect(find.text('Stanford CS229: Machine Learning'), findsWidgets);
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Delete goal');
  await tapText(tester, 'Delete');
  expect(find.text('Stanford CS229: Machine Learning'), findsNothing);
  expect(find.text('0 of 3 done today'), findsOneWidget);
}

/// Habits: check and undo, an avoid habit, and a checklist.
Future<void> moreHabitsFlow(WidgetTester tester) async {
  await tapKey(tester, 'empty-samples');
  await _tapIn(tester, 'meditate', find.text('Mark done'));
  expect(_inTile('meditate', find.text('Done ✓')), findsOneWidget);
  await _tapIn(tester, 'meditate', find.text('Done ✓'));
  expect(_inTile('meditate', find.text('Mark done')), findsOneWidget);
  expect(_inTile('meditate', find.text('Not done yet')), findsOneWidget);

  await importPlan(
    tester,
    jsonEncode({
      'kind': 'goal',
      'schemaVersion': '1.0',
      'id': 'no-sugar',
      'template': 'habit@1',
      'title': 'No sugar',
      'data': {'mode': 'check', 'avoid': true},
    }),
  );
  expect(_inTile('no-sugar', find.text('Clean today')), findsOneWidget);
  await _tapIn(tester, 'no-sugar', find.text('I slipped'));
  expect(_inTile('no-sugar', find.text('Slipped today')), findsOneWidget);
  await _tapIn(tester, 'no-sugar', find.text('Undo slip'));
  expect(_inTile('no-sugar', find.text('Clean today')), findsOneWidget);

  await importPlan(
    tester,
    jsonEncode({
      'kind': 'goal',
      'schemaVersion': '1.0',
      'id': 'morning',
      'template': 'habit@1',
      'title': 'Morning routine',
      'data': {
        'mode': 'checklist',
        'steps': [
          {'id': 'stretch', 'title': 'Stretch'},
          {'id': 'journal', 'title': 'Journal'},
        ],
      },
    }),
  );
  await tapText(tester, 'Morning routine');
  await tapKey(tester, 'check:Stretch');
  expect(find.text('1 / 2'), findsOneWidget);
  await tapKey(tester, 'check:Journal');
  expect(find.text('2 / 2'), findsOneWidget);
  await tapKey(tester, 'check:Journal');
  expect(find.text('1 / 2'), findsOneWidget);
  await tapKey(tester, 'check:Journal');
  await goBack(tester);
  expect(_inTile('morning', find.text('2 of 2 steps')), findsOneWidget);
}

/// Book: "Mark today done" completes today's pages.
Future<void> bookMarkTodayFlow(WidgetTester tester) async {
  await importPlan(tester, await sampleText('book-atomic-habits.getonit.json'));
  await tapText(tester, 'Read Atomic Habits · Page 0 of 320');
  await tapText(tester, 'Mark today done');
  expect(find.text('✓ Done today'), findsOneWidget);
  expect(find.textContaining('Page 2 of 320'), findsOneWidget);
  await goBack(tester);
  expect(_inTile('atomic-habits', find.text('✓ Today')), findsOneWidget);
}

/// Import: the Paste button reads the clipboard; "Copy for Claude" writes the
/// errors to it.
Future<void> clipboardFlow(WidgetTester tester) async {
  await Clipboard.setData(ClipboardData(text: await sampleText('habit-water.getonit.json')));
  await tapKey(tester, 'empty-import');
  await tapText(tester, 'Paste');
  await waitFor(tester, find.text('8 glasses per day'));
  expect(find.text('8 glasses per day'), findsOneWidget);
  await tapKey(tester, 'import-confirm');
  expect(find.text('Drink water'), findsOneWidget);

  await pastePlan(
    tester,
    '{"kind":"goal","schemaVersion":"1.0","id":"x","template":"course@1","title":"T","data":{"items":[]}}',
  );
  await tapKey(tester, 'fix-copy');
  final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  expect(copied, contains('You fix plans'));
  expect(copied, contains('data.items'));
  expect(copied, contains('"id":"x"'));
  await goBack(tester);
}

/// A minute of the day as the app shows it here: the phone's 24-hour setting
/// decides "19:00" or "7:00 PM".
String hm(WidgetTester tester, int minuteOfDay) =>
    clockDisplay(minuteOfDay, use24h: tester.platformDispatcher.alwaysUse24HourFormat);

/// Settings: change "My day starts at" and copy the capability manifest.
Future<void> settingsFlow(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await settle(tester);
  await tapText(tester, hm(tester, 0));
  await tester.tap(find.text(hm(tester, 4 * 60)).last);
  await settle(tester);
  expect(find.text(hm(tester, 4 * 60)), findsOneWidget);
  expect(find.text(hm(tester, 0)), findsNothing);

  await tapText(tester, 'Capability manifest');
  expect(find.text('Copied'), findsOneWidget);
  final manifest = jsonDecode((await Clipboard.getData(Clipboard.kTextPlain))!.text!) as Map;
  expect(manifest['components'], contains('progress_ring'));
  expect(manifest['engines'], contains('page_range'));
  await goBack(tester);
}

/// Google Drive: connect, back up, automatic backup after a change, delete a
/// goal and restore it, delete the backup, disconnect.
Future<void> driveFlow(WidgetTester tester, Fakes fakes, {required Future<void> Function() waitAutoBackup}) async {
  await tapKey(tester, 'empty-samples');
  final water = find.byKey(const ValueKey('goal-tile:water'));
  await tester.ensureVisible(water);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: water, matching: find.byKey(const ValueKey('counter:increment'))));
  await settle(tester);

  Future<void> openSettings() async {
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await _reveal(tester, find.byKey(const ValueKey('drive-backup-buttons')));
    await tester.pumpAndSettle();
  }

  await openSettings();
  expect(find.text('Connect Google Drive'), findsOneWidget);
  await tapKey(tester, 'drive-connect');
  expect(find.textContaining('Connected as test@example.com'), findsWidgets);
  await tapKey(tester, 'drive-backup');
  expect(find.byKey(const ValueKey('drive-last-backup')), findsOneWidget);
  expect(fakes.drive.files.keys, containsAll(['goals/water.json', 'goals/stanford-cs229.json', 'settings.json']));
  String waterEvents() => fakes.drive.files.entries
      .where((e) => e.key.startsWith('events/'))
      .map((e) => e.value)
      .join()
      .split('\n')
      .where((l) => l.contains('"goal":"water"'))
      .join('\n');
  expect(RegExp('count_delta').allMatches(waterEvents()), hasLength(1));
  await goBack(tester);

  // A change is backed up on its own after a short wait.
  await tester.tap(find.descendant(of: water, matching: find.byKey(const ValueKey('counter:increment'))));
  await settle(tester);
  await waitAutoBackup();
  expect(RegExp('count_delta').allMatches(waterEvents()), hasLength(2));

  // Lose the goal, then restore it from Drive with its progress.
  await tapText(tester, 'Drink water');
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Delete goal');
  await tapText(tester, 'Delete');
  expect(find.text('Drink water'), findsNothing);
  await openSettings();
  await tapKey(tester, 'drive-restore');
  await tester.tap(find.text('Restore').last);
  await settle(tester);
  await goBack(tester);
  expect(find.descendant(of: water, matching: find.text('2 / 8 glasses')), findsOneWidget);

  await openSettings();
  await tapKey(tester, 'drive-delete');
  await tester.tap(find.text('Delete').last);
  await settle(tester);
  expect(fakes.drive.files, isEmpty);
  await tapKey(tester, 'drive-disconnect');
  expect(find.text('Connect Google Drive'), findsOneWidget);
  expect(fakes.driveAccount.signedIn, false);
  await goBack(tester);
}

const _strictHabit = {
  'kind': 'goal',
  'schemaVersion': '1.0',
  'id': 'stretch',
  'template': 'habit@1',
  'title': 'Stretch',
  'icon': '🤸',
  'reminders': {'preset': 'strict', 'time': '19:00'},
  'data': {'mode': 'check'},
};

/// Turns on the strict habit's reminders, lets one ring, snoozes another, and
/// returns the one on screen. Expects the clock at 09:00.
Future<PlannedReminder> _ringingHabit(WidgetTester tester, FakeGateway n) async {
  await pastePlan(tester, jsonEncode(_strictHabit));
  await tapKey(tester, 'import-reminders:stretch');
  await tapKey(tester, 'import-confirm');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  final today = n.reminders.toList()..sort((a, b) => a.localTime.compareTo(b.localTime));
  n.fire(today[0].id);
  n.tap(today[1], action: 'snooze');
  await settle(tester);
  expect(n.onScreen, hasLength(1));
  expect(n.scheduled.keys.where((id) => id & snoozeBit != 0), hasLength(1));
  return today[0];
}

/// Deleting a goal stops everything it rang or will ring: the schedule, the
/// snoozed reminder, the reminder on screen, and its nudges. Its reminder
/// switch does not come back with a re-import.
Future<void> deleteStopsRemindersFlow(WidgetTester tester, Fakes fakes) async {
  final n = fakes.notifications;
  await _ringingHabit(tester, n);
  expect((fakes.nudges.last['pending'] as List).map((p) => (p as Map)['goalId']), contains('stretch'));

  await tapText(tester, 'Stretch');
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Delete goal');
  await tapText(tester, 'Delete');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  expect(n.scheduled, isEmpty, reason: 'no scheduled or snoozed reminder is left');
  expect(n.onScreen, isEmpty, reason: 'the reminder on screen goes too');
  expect((fakes.nudges.last['pending'] as List).map((p) => (p as Map)['goalId']), isNot(contains('stretch')));

  await pastePlan(tester, jsonEncode(_strictHabit));
  final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('import-reminders:stretch')));
  expect(sw.value, false, reason: 'a deleted goal forgets its reminder switch');
  await goBack(tester);
}

/// Finishing today's work takes the goal's ringing and snoozed reminders
/// away; tomorrow's stay.
Future<void> doneClearsRemindersFlow(WidgetTester tester, Fakes fakes) async {
  final n = fakes.notifications;
  final ringing = await _ringingHabit(tester, n);
  n.tap(ringing, action: 'done');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  expect(n.onScreen, isEmpty);
  expect(n.scheduled.keys.where((id) => id & snoozeBit != 0), isEmpty);
  expect(n.reminders.where((r) => r.day == ringing.day), isEmpty);
  expect(n.reminders.where((r) => r.day > ringing.day), isNotEmpty);
}

/// Reminders: approval in the import preview, the plan in the notification
/// system, today done, pause and resume, permissions, the goal menu switch,
/// and the Done and Snooze buttons. Expects the clock at 09:00.
Future<void> remindersFlow(WidgetTester tester, Fakes fakes) async {
  final n = fakes.notifications;
  await pastePlan(tester, jsonEncode(_strictHabit));
  expect(find.text('Turn on the reminders in this plan'), findsOneWidget);
  expect(
    find.textContaining(
      '${hm(tester, 19 * 60)} notification → ${hm(tester, 19 * 60 + 30)} notification that stays → '
      '${hm(tester, 20 * 60)} alarm → ${hm(tester, 20 * 60 + 30)} alarm that rings until you start',
    ),
    findsOneWidget,
  );
  await tapKey(tester, 'import-confirm');
  await settle(tester);
  expect(n.scheduled, isEmpty, reason: 'imported reminders stay off until the user turns them on');

  await pastePlan(tester, jsonEncode(_strictHabit));
  await tapKey(tester, 'import-reminders:stretch');
  await tapKey(tester, 'import-confirm');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  expect(n.scheduled, hasLength(28), reason: '4 steps on each of 7 days');

  // Importing the plan again shows the reminders as on, and keeps them on.
  await pastePlan(tester, jsonEncode(_strictHabit));
  final sw = tester.widget<SwitchListTile>(find.byKey(const ValueKey('import-reminders:stretch')));
  expect(sw.value, true);
  await tapKey(tester, 'import-confirm');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  expect(n.scheduled, hasLength(28));

  Future<void> openSettings() async {
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
  }

  await openSettings();
  expect(find.text('28 reminders planned for the next 7 days'), findsOneWidget);
  // Permissions: shown as missing, then allowed.
  expect(find.descendant(of: find.byKey(const ValueKey('perm-exact')), matching: find.text('Allow')), findsOneWidget);
  await tester.tap(find.descendant(of: find.byKey(const ValueKey('perm-exact')), matching: find.text('Allow')));
  await settle(tester);
  expect(find.descendant(of: find.byKey(const ValueKey('perm-exact')), matching: find.text('Allow')), findsNothing);
  // Pause for 1 day: today's 4 go.
  await tapKey(tester, 'pause-menu');
  await tapText(tester, '1 day');
  expect(find.textContaining('Paused until'), findsOneWidget);
  expect(n.scheduled, hasLength(24));
  await tapKey(tester, 'pause-resume');
  expect(n.scheduled, hasLength(28));
  await goBack(tester);

  // Done today: today's remaining reminders are cancelled.
  final today = n.reminders.map((r) => r.day).reduce((a, b) => a < b ? a : b);
  final first = n.reminders.firstWhere((r) => r.day == today && r.level == ReminderLevel.notification);
  n.tap(first, action: 'done');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  expect(n.reminders.where((r) => r.day == today), isEmpty);
  expect(n.scheduled, hasLength(24));
  expect(
    find.descendant(of: find.byKey(const ValueKey('goal-tile:stretch')), matching: find.text('Done today')),
    findsOneWidget,
  );

  // Snooze schedules one ring 10 minutes later, with its own id.
  final tomorrowSticky = n.reminders.firstWhere((r) => r.day == today + 1 && r.level == ReminderLevel.sticky);
  n.tap(tomorrowSticky, action: 'snooze');
  await settle(tester);
  final snoozed = n.scheduled.entries.where((e) => e.key & snoozeBit != 0).toList();
  expect(snoozed, hasLength(1));

  // A plain tap opens the goal.
  n.tap(tomorrowSticky);
  await settle(tester);
  expect(find.byKey(const ValueKey('goal-menu')), findsOneWidget);

  // The goal menu turns reminders off; the snoozed ring stays.
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Turn reminders off');
  expect(n.scheduled.keys.where((id) => id & snoozeBit == 0), isEmpty);
  await tapKey(tester, 'goal-menu');
  final turnOn = 'Turn reminders on (strict, from ${hm(tester, 19 * 60)})';
  expect(find.text(turnOn), findsOneWidget);
  await tapText(tester, turnOn);
  expect(n.scheduled.keys.where((id) => id & snoozeBit == 0), hasLength(24));
  await goBack(tester);
}

/// Alarms: a strict alarm cannot be closed until progress, rings again when
/// left, ends when the task is done, and has a 10-second emergency exit. A
/// normal alarm has Snooze and Done today.
Future<void> alarmFlow(WidgetTester tester, Fakes fakes, {void Function(Duration)? advance}) async {
  final n = fakes.notifications;
  await pastePlan(tester, jsonEncode(_strictHabit));
  await tapKey(tester, 'import-reminders:stretch');
  await tapKey(tester, 'import-confirm');
  await tester.pump(const Duration(seconds: 1));
  await settle(tester);
  final today = n.reminders.map((r) => r.day).reduce((a, b) => a < b ? a : b);
  final strict = n.reminders.firstWhere((r) => r.day == today && r.level == ReminderLevel.strictAlarm);

  // The strict alarm rings.
  n.tap(strict);
  await settle(tester);
  expect(find.byKey(const ValueKey('alarm-title')), findsOneWidget);
  expect(find.text('This alarm stops when you make progress.'), findsOneWidget);
  expect(n.cancelled, contains(strict.id), reason: 'opening the alarm stops its sound');
  final reRing = n.scheduled.keys.where((id) => id & snoozeBit != 0).toList();
  expect(reRing, hasLength(1), reason: 'it rings again in 3 minutes unless there is progress');
  expect(find.byKey(const ValueKey('alarm-dismiss')), findsNothing);
  await tester.binding.handlePopRoute();
  await settle(tester);
  expect(find.byKey(const ValueKey('alarm-title')), findsOneWidget, reason: 'Back does not close a strict alarm');

  // Get on it → the goal; doing the task ends the alarm.
  await tapKey(tester, 'alarm-start');
  expect(find.byKey(const ValueKey('goal-menu')), findsOneWidget);
  await tapText(tester, 'Mark done');
  await goBack(tester);
  expect(find.text('Done for now ✓'), findsOneWidget);
  expect(n.scheduled.keys.where((id) => id & snoozeBit != 0), isEmpty, reason: 'the re-ring is cancelled');
  await tapKey(tester, 'alarm-close');
  expect(find.byKey(const ValueKey('alarm-title')), findsNothing);

  // Undo, so the next alarm has work to wait for. The test clock is frozen,
  // so it moves on first: events at the same moment have no fixed order.
  advance?.call(const Duration(minutes: 1));
  await _undoStretch(tester);
  advance?.call(const Duration(minutes: 1));

  // Emergency exit: hold 10 seconds, then "Skip today".
  n.tap(strict);
  await settle(tester);
  final hold = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('alarm-emergency'))));
  await tester.pump(const Duration(seconds: 5));
  await hold.up();
  await settle(tester);
  expect(find.text('Skip today?'), findsNothing, reason: '5 seconds is not enough');
  final hold2 = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('alarm-emergency'))));
  await tester.pump(const Duration(milliseconds: 600));
  for (var i = 0; i < 11; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await hold2.up();
  await settle(tester);
  expect(find.text('Skip today?'), findsOneWidget);
  await tapText(tester, 'Skip today');
  expect(find.byKey(const ValueKey('alarm-title')), findsNothing);
  expect(n.scheduled.keys.where((id) => id & snoozeBit != 0), isEmpty);

  // A normal alarm: Snooze, then Done today.
  final alarm = n.reminders.firstWhere((r) => r.day == today + 1 && r.level == ReminderLevel.alarm);
  n.tap(alarm);
  await settle(tester);
  expect(find.text('Snooze 10 min'), findsOneWidget);
  await tapKey(tester, 'alarm-snooze');
  expect(find.byKey(const ValueKey('alarm-title')), findsNothing);
  expect(n.scheduled.keys.where((id) => id & snoozeBit != 0), hasLength(1));
  n.tap(alarm);
  await settle(tester);
  await tapKey(tester, 'alarm-done');
  expect(
    find.descendant(of: find.byKey(const ValueKey('goal-tile:stretch')), matching: find.text('Done today')),
    findsOneWidget,
  );
}

Future<void> _undoStretch(WidgetTester tester) async {
  final tile = find.byKey(const ValueKey('goal-tile:stretch'));
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: tile, matching: find.text('Done ✓')));
  await settle(tester);
  expect(find.descendant(of: tile, matching: find.text('Mark done')), findsOneWidget);
}

/// Distraction nudges: enable, today's open work goes to the service, the
/// unlock switch, usage access, suggested apps in the picker, and open work
/// shrinking as goals are done.
Future<void> nudgesFlow(WidgetTester tester, Fakes fakes, {required Future<void> Function() waitPush}) async {
  final b = fakes.nudges;
  await tapKey(tester, 'empty-samples');
  await tester.tap(find.byTooltip('Settings'));
  await settle(tester);
  await tapKey(tester, 'nudges-enabled');
  await waitPush();
  expect(b.last['enabled'], true);
  final pending = (b.last['pending'] as List).cast<Map>();
  expect(pending.map((p) => p['goalId']), ['stanford-cs229', 'atomic-habits', 'water', 'meditate']);
  expect(pending.first['link'], 'getonit://start/stanford-cs229');
  expect(pending.first['title'], 'Stanford CS229: Machine Learning');
  expect(b.last['quietStartMin'], 23 * 60);
  expect(find.text('On. 4 goals still open today.'), findsOneWidget);

  await tapKey(tester, 'nudges-unlock');
  await waitPush();
  expect(b.last['unlock'], false);
  await tapKey(tester, 'nudges-unlock');
  await waitPush();

  // Usage access is granted in system settings; the app reads it on return.
  await tester.tap(
    find.descendant(of: find.byKey(const ValueKey('nudges-usage-access')), matching: find.text('Allow')),
  );
  await settle(tester);
  // The steps for Android's restricted setting come first.
  expect(find.byKey(const ValueKey('usage-help')), findsOneWidget);
  await tapKey(tester, 'usage-open-settings');
  await tapKey(tester, 'usage-close');
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await settle(tester);
  expect(
    find.descendant(of: find.byKey(const ValueKey('nudges-usage-access')), matching: find.text('Allow')),
    findsNothing,
  );

  // The plan suggested Instagram and YouTube; they come first.
  await tapKey(tester, 'nudges-choose');
  expect(find.text('Suggested by your plan'), findsNWidgets(2));
  await tapKey(tester, 'app:com.instagram.android');
  await tapKey(tester, 'apps-save');
  await waitPush();
  expect(find.text('Instagram (15 min)'), findsOneWidget);
  expect(b.last['apps'], [
    {'package': 'com.instagram.android', 'label': 'Instagram', 'thresholdMin': 15},
  ]);
  await goBack(tester);

  // Done goals leave the list.
  final meditate = find.byKey(const ValueKey('goal-tile:meditate'));
  await tester.ensureVisible(meditate);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: meditate, matching: find.text('Mark done')));
  await settle(tester);
  await waitPush();
  expect((b.last['pending'] as List).map((p) => (p as Map)['goalId']), ['stanford-cs229', 'atomic-habits', 'water']);
}

/// Home-screen widgets: the app keeps the widget trees current.
Future<void> widgetsFlow(WidgetTester tester, Fakes fakes, {required Future<void> Function() waitPush}) async {
  final w = fakes.widgets;
  await tapKey(tester, 'empty-samples');
  await waitPush();
  expect(w.refreshes, greaterThan(0));
  expect(w.data['today'], contains('0 of 4 done'));
  expect(w.data['goal:water:medium'], contains('0 / 8 glasses'));
  final water = find.byKey(const ValueKey('goal-tile:water'));
  await tester.ensureVisible(water);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: water, matching: find.byKey(const ValueKey('counter:increment'))));
  await settle(tester);
  await waitPush();
  expect(w.data['goal:water:medium'], contains('1 / 8 glasses'));
}

/// No skill installed: make a prompt, "ask" an AI, paste its whole answer.
Future<void> askAiFlow(WidgetTester tester, Fakes fakes) async {
  await tapKey(tester, 'empty-ask');
  await tapText(tester, 'Drink 8 glasses of water a day');
  await tapKey(tester, 'ask-copy');
  final prompt = (await Clipboard.getData(Clipboard.kTextPlain))!.text!;
  expect(prompt, contains('Drink 8 glasses of water a day'));
  expect(prompt, contains('habit@1'));
  await tapKey(tester, 'ask-claude');
  expect(fakes.launched.last.toString(), 'https://claude.ai/new');
  await tapKey(tester, 'ask-chatgpt');
  expect(fakes.launched.last.toString(), 'https://chatgpt.com/');

  // A typical answer: a sentence, the code block, a sentence.
  final answer =
      'Here is your plan.\n\n```json\n${await sampleText('habit-water.getonit.json')}\n```\n\nImport it in Get On It.';
  await _snackGone(tester);
  await tapKey(tester, 'ask-import');
  await tester.enterText(find.byKey(const ValueKey('import-text')), answer);
  await checkPlan(tester);
  expect(find.text('8 glasses per day'), findsOneWidget);
  await tapKey(tester, 'import-confirm');
  expect(find.text('Drink water'), findsOneWidget);
}

/// Change a plan with AI: the prompt carries the plan and progress; the
/// answer comes back as an update that keeps progress.
Future<void> editAiFlow(WidgetTester tester, Fakes fakes) async {
  await importPlan(tester, await sampleText('course-cs229.getonit.json'));
  await tapText(tester, 'Stanford CS229: Machine Learning');
  await tapText(tester, 'Mark done');
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Change plan with AI');
  expect(find.text('Change this plan with AI'), findsOneWidget);
  await tapText(tester, 'Move the deadline two weeks later');
  await tapKey(tester, 'ask-copy');
  final prompt = (await Clipboard.getData(Clipboard.kTextPlain))!.text!;
  expect(prompt, contains('Move the deadline two weeks later'));
  expect(prompt, contains('"id": "stanford-cs229"'));
  expect(prompt, contains('Done item ids: lec-01'));

  // The AI's answer: the same plan with a later deadline.
  final doc = (jsonDecode(await sampleText('course-cs229.getonit.json')) as Map).cast<String, Object?>();
  doc['deadline'] = '2027-01-14';
  await _snackGone(tester);
  await tapKey(tester, 'ask-import');
  await tester.enterText(find.byKey(const ValueKey('import-text')), '```json\n${jsonEncode(doc)}\n```');
  await checkPlan(tester);
  expect(find.text('No changes to items. Your progress stays.'), findsOneWidget);
  expect(find.textContaining('deadline 14 Jan'), findsOneWidget);
  await tapKey(tester, 'import-confirm');
  await tapText(tester, 'Stanford CS229: Machine Learning');
  expect(find.text('1 of 21 videos'), findsWidgets);

  // Change only the look: the prompt has the plan and its template.
  await tapKey(tester, 'goal-menu');
  await tapText(tester, 'Change the look with AI');
  expect(find.text('Change the look with AI'), findsOneWidget);
  await tapText(tester, 'Show my streak and the week on the medium widget');
  await tapKey(tester, 'ask-copy');
  final look = (await Clipboard.getData(Clipboard.kTextPlain))!.text!;
  expect(look, contains('Change how one goal looks'));
  expect(look, contains('Show my streak and the week on the medium widget'));
  expect(look, contains('"engine": "video_series"'));
  expect(look, contains('"deadline": "2027-01-14"'));

  // The AI's answer: the course template under a new id, with a new line on
  // top, and the same goal pointing at it. Progress stays.
  final template = (jsonDecode(await rootBundle.loadString('assets/templates/course.json')) as Map)
      .cast<String, Object?>();
  template['id'] = 'stanford-cs229-look';
  template['version'] = '1.0.0';
  final screen = ((template['surfaces'] as Map)['screen'] as Map).cast<String, Object?>();
  screen['children'] = [
    {'type': 'text', 'style': 'title', 'value': 'My new look'},
    ...(screen['children'] as List),
  ];
  doc['template'] = 'stanford-cs229-look@1';
  await _snackGone(tester);
  await tapKey(tester, 'ask-import');
  await tester.enterText(
    find.byKey(const ValueKey('import-text')),
    jsonEncode({
      'kind': 'bundle',
      'schemaVersion': '1.0',
      'documents': [template, doc],
    }),
  );
  await checkPlan(tester);
  expect(find.text('No changes to items. Your progress stays.'), findsOneWidget);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('surface-preview:stanford-cs229:screen')),
      matching: find.text('My new look'),
    ),
    findsOneWidget,
  );
  await tapKey(tester, 'import-confirm');
  await tapText(tester, 'Stanford CS229: Machine Learning');
  expect(find.text('My new look'), findsOneWidget);
  expect(find.text('1 of 21 videos'), findsWidgets);
  await goBack(tester);
}

/// The "Prompt copied" message covers the bottom of the screen for a few
/// seconds, as for a real user.
Future<void> _snackGone(WidgetTester tester) async {
  // Host tests run on fake time; on a device the timer runs on real time.
  final live = tester.binding is LiveTestWidgetsFlutterBinding;
  for (var i = 0; i < 12 && find.byType(SnackBar).evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (live) await Future<void>.delayed(const Duration(seconds: 1));
  }
  await tester.pumpAndSettle();
}
