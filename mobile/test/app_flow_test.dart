import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  Future<void> start(WidgetTester tester, {TestClock? clock}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    // The asset cache holds futures from the previous test's fake-time zone,
    // which never complete in this one.
    rootBundle.clear();
    // Made inside the test so its streams run in the test's fake-time zone.
    final db = memoryDatabase();
    addTearDown(db.close);
    await tester.pumpWidget(buildTestApp(db: db, clock: clock));
    await settle(tester);
    expect(find.text('No goals yet'), findsOneWidget);
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('course: import, open, mark done, re-import keeps progress', (tester) async {
    await start(tester);
    await courseFlow(tester);
    await reimportFlow(tester);
    await stop(tester);
  });

  testWidgets('book: log a page by hand', (tester) async {
    await start(tester);
    await bookFlow(tester);
    await stop(tester);
  });

  testWidgets('habits: counter and check on the Today tiles', (tester) async {
    await start(tester);
    await habitCounterFlow(tester);
    await stop(tester);
  });

  testWidgets('invalid plan shows errors', (tester) async {
    await start(tester);
    await invalidPlanFlow(tester);
    await stop(tester);
  });

  testWidgets('a new day resets daily habits and keeps the streak', (tester) async {
    final clock = TestClock(DateTime(2026, 10, 21, 9));
    await start(tester, clock: clock);
    await habitCounterFlow(tester);

    clock.now = DateTime(2026, 10, 22, 9);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);

    final meditate = find.byKey(const ValueKey('goal-tile:meditate'));
    expect(find.descendant(of: meditate, matching: find.text('Not done yet')), findsOneWidget);
    expect(find.text('0 of 4 done today'), findsOneWidget);
    await stop(tester);
  });
}
