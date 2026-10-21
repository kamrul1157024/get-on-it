import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<void> tapText(WidgetTester tester, String text) async {
  final f = find.text(text).first;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await settle(tester);
}

Future<void> tapKey(WidgetTester tester, String key) async {
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
  await tapKey(tester, 'import-check');
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
  await tapKey(tester, 'empty-samples');
  await _tapIn(tester, 'stanford-cs229', find.text('▶ Resume 0:00'));
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
  expect(_inTile('stanford-cs229', find.text('▶ Resume 2:00')), findsOneWidget);

  await _tapIn(tester, 'stanford-cs229', find.text('▶ Resume 2:00'));
  expect(fakes.video.startSec, 120);
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

  await tapText(tester, 'Lecture 3: Locally Weighted & Logistic Regression');
  expect(fakes.video.videoId, 'het9HFqo1TQ');
  await goBack(tester);

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
  expect(find.text('8 glasses per day'), findsOneWidget);
  await tapKey(tester, 'import-confirm');
  expect(find.text('Drink water'), findsOneWidget);

  await pastePlan(
    tester,
    '{"kind":"goal","schemaVersion":"1.0","id":"x","template":"course@1","title":"T","data":{"items":[]}}',
  );
  await tapText(tester, 'Copy for Claude');
  final copied = await Clipboard.getData(Clipboard.kTextPlain);
  expect(copied?.text, contains('data.items'));
  await goBack(tester);
}

/// Settings: change "My day starts at" and copy the capability manifest.
Future<void> settingsFlow(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await settle(tester);
  await tapText(tester, '00:00');
  await tester.tap(find.text('04:00').last);
  await settle(tester);
  expect(find.text('04:00'), findsOneWidget);
  expect(find.text('00:00'), findsNothing);

  await tapText(tester, 'Capability manifest');
  expect(find.text('Copied'), findsOneWidget);
  final manifest = jsonDecode((await Clipboard.getData(Clipboard.kTextPlain))!.text!) as Map;
  expect(manifest['components'], contains('progress_ring'));
  expect(manifest['engines'], contains('page_range'));
  await goBack(tester);
}
