import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  Future<Fakes> start(WidgetTester tester, {TestClock? clock, bool listenForIntents = false}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    // The asset cache holds futures from the previous test's fake-time zone,
    // which never complete in this one.
    rootBundle.clear();
    // Made inside the test so its streams run in the test's fake-time zone.
    final db = memoryDatabase();
    addTearDown(db.close);
    final fakes = Fakes();
    await tester.pumpWidget(buildTestApp(db: db, clock: clock, fakes: fakes, listenForIntents: listenForIntents));
    await settle(tester);
    return fakes;
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> run(WidgetTester tester, Future<void> Function(Fakes) flow) async {
    final fakes = await start(tester);
    expect(find.text('No goals yet'), findsOneWidget);
    await flow(fakes);
    await stop(tester);
  }

  testWidgets('course: import, open, mark done, re-import keeps progress', (tester) async {
    await run(tester, (_) async {
      await courseFlow(tester);
      await reimportFlow(tester);
    });
  });

  testWidgets('player: resume, save positions, YouTube link, mark done', (tester) async {
    await run(tester, (f) => playerFlow(tester, f));
  });

  testWidgets('course screen: lecture list, task toggle, open task, delete', (tester) async {
    await run(tester, (f) => courseScreenFlow(tester, f));
  });

  testWidgets('book: log a page by hand', (tester) async {
    await run(tester, (_) => bookFlow(tester));
  });

  testWidgets('book: mark today done', (tester) async {
    await run(tester, (_) => bookMarkTodayFlow(tester));
  });

  testWidgets('habits: counter and check on the Today tiles', (tester) async {
    await run(tester, (_) => habitCounterFlow(tester));
  });

  testWidgets('habits: check undo, avoid habit, checklist', (tester) async {
    await run(tester, (_) => moreHabitsFlow(tester));
  });

  testWidgets('import: paste button and copy errors for Claude', (tester) async {
    await run(tester, (_) => clipboardFlow(tester));
  });

  testWidgets('invalid plan shows errors', (tester) async {
    await run(tester, (_) => invalidPlanFlow(tester));
  });

  testWidgets('settings: day start and capability manifest', (tester) async {
    await run(tester, (_) => settingsFlow(tester));
  });

  testWidgets('drive: connect, back up, auto backup, restore, delete, disconnect', (tester) async {
    await run(
      tester,
      (f) => driveFlow(
        tester,
        f,
        waitAutoBackup: () async {
          await tester.pump(const Duration(seconds: 3));
          await settle(tester);
        },
      ),
    );
  });

  testWidgets('reminders: approval, plan, done, pause, snooze, goal menu', (tester) async {
    final fakes = await start(tester, clock: TestClock(DateTime(2026, 10, 21, 9)));
    await remindersFlow(tester, fakes);
    await stop(tester);
  });

  testWidgets('alarms: strict challenge, re-ring, emergency exit, snooze', (tester) async {
    final clock = TestClock(DateTime(2026, 10, 21, 9));
    final fakes = await start(tester, clock: clock);
    await alarmFlow(tester, fakes, advance: (d) => clock.now = clock.now.add(d));
    await stop(tester);
  });

  testWidgets('a shared plan opens the import preview', (tester) async {
    const channel = MethodChannel('app.getonit/intents');
    // Read before start(), so the asset cache from the last test must go first.
    rootBundle.clear();
    final json = await sampleText('habit-water.getonit.json');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'getInitialText' ? json : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await start(tester, listenForIntents: true);
    expect(find.text('Import a plan'), findsWidgets);
    expect(find.text('8 glasses per day'), findsOneWidget);
    await tapKey(tester, 'import-confirm');
    expect(find.text('Drink water'), findsOneWidget);
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
