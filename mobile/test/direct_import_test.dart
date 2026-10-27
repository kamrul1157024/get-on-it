import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/features/import/plan_finder.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
    await tester.pumpWidget(buildTestApp(db: db, fakes: Fakes(), listenForIntents: true));
    await settle(tester);
  }

  /// A plan shared from another app, as from ChatGPT's Share.
  Future<void> share(WidgetTester tester, String text) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.getonit/intents',
      const StandardMethodCodec().encodeMethodCall(MethodCall('onText', text)),
      (_) {},
    );
    await waitFor(
      tester,
      find.byWidgetPredicate((w) => w.key == const ValueKey('import-done') || w.key == const ValueKey('import-errors')),
    );
  }

  Map<String, Object?> sample(String json) => (jsonDecode(json) as Map).cast<String, Object?>();

  final done = find.byKey(const ValueKey('import-done'));

  testWidgets('a clean plan is saved at once, its page opens, and Undo removes it', (tester) async {
    await start(tester);
    await share(tester, await sampleText('habit-water.getonit.json'));
    expect(find.byKey(const ValueKey('import-confirm')), findsNothing);
    expect(find.text('Plan added.'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Drink water'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('import-undo')));
    await settle(tester);
    expect(find.text('No goals yet'), findsOneWidget);
  });

  testWidgets('an update of the same goal says so, and Undo brings the old version back', (tester) async {
    await start(tester);
    final water = sample(await sampleText('habit-water.getonit.json'));
    await share(tester, jsonEncode(water));
    await goBack(tester);
    await tester.pump(const Duration(seconds: 9)); // the first message goes
    await settle(tester);

    await share(tester, jsonEncode({...water, 'title': 'Drink more water'}));
    expect(find.text('Plan updated.'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Drink more water'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-undo')));
    await settle(tester);
    expect(find.widgetWithText(AppBar, 'Drink water'), findsOneWidget);
  });

  testWidgets('a plan with a problem opens the import screen with the problem', (tester) async {
    await start(tester);
    await share(
      tester,
      '{"kind":"goal","schemaVersion":"1.0","id":"x","template":"course@1","title":"T","data":{"items":[]}}',
    );
    expect(done, findsNothing);
    expect(find.byKey(const ValueKey('import-errors')), findsOneWidget);
    expect(find.byKey(const ValueKey('fix-with-ai')), findsOneWidget);
  });

  testWidgets('several goals in one plan: all are added, outlined on Today, and one Undo removes all', (tester) async {
    await start(tester);
    final plan = jsonEncode({
      'kind': 'bundle',
      'schemaVersion': '1.0',
      'documents': [
        sample(await sampleText('habit-exercise.getonit.json')),
        sample(await sampleText('book-atomic-habits.getonit.json')),
        sample(await sampleText('habit-water.getonit.json')),
      ],
    });
    expect(planIn(plan)?.title, '3 goals');
    await share(tester, plan);
    expect(find.text('3 goals added.'), findsOneWidget);
    for (final id in ['exercise-week', 'atomic-habits', 'water']) {
      expect(find.byKey(ValueKey('goal-tile:$id')), findsOneWidget, reason: id);
    }
    await tester.tap(find.byKey(const ValueKey('import-undo')));
    await settle(tester);
    expect(find.text('No goals yet'), findsOneWidget);
  });

  testWidgets('a problem in one goal of several is shown under that goal', (tester) async {
    await start(tester);
    final water = sample(await sampleText('habit-water.getonit.json'));
    await share(
      tester,
      jsonEncode({
        'kind': 'bundle',
        'schemaVersion': '1.0',
        'documents': [
          water,
          {...water, 'id': 'broken', 'title': 'Broken goal', 'data': <String, Object?>{}},
        ],
      }),
    );
    expect(find.byKey(const ValueKey('import-errors-group:Broken goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('import-errors-group:Drink water')), findsNothing);
  });

  testWidgets('the plan page asks once to turn on the reminders the plan proposes', (tester) async {
    await start(tester);
    await share(tester, await sampleText('habit-exercise.getonit.json'));
    final ask = find.byKey(const ValueKey('reminder-ask'));
    expect(ask, findsOneWidget);
    expect(find.text('Turn on reminders at 6:30 PM?'), findsOneWidget);
    await tapKey(tester, 'reminder-ask-no');
    expect(ask, findsNothing);
    await goBack(tester);
    await tapText(tester, 'Exercise 4 days a week');
    expect(ask, findsNothing);
  });
}
