import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
