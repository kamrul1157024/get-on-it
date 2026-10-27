import 'dart:convert';

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
    // Tear-downs run last-first: the app goes away before its database
    // closes. A failed test skips stop(), and closing the database under a
    // live app hung every test after it.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
    final fakes = Fakes();
    await tester.pumpWidget(buildTestApp(db: db, clock: clock, fakes: fakes, listenForIntents: listenForIntents));
    await settle(tester);
    return fakes;
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> run(WidgetTester tester, Future<void> Function(Fakes) flow, {TestClock? clock}) async {
    final fakes = await start(tester, clock: clock);
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

  testWidgets('import preview: real surfaces, broken layout blocks, fix with AI', (tester) async {
    await run(tester, (_) => previewFlow(tester));
  });

  testWidgets('time lost today: card, what it could have been, exclude and undo', (tester) async {
    await run(tester, (f) => timeLostFlow(tester, f), clock: TestClock(DateTime(2026, 10, 21, 9)));
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

  testWidgets('deleting a goal stops its reminders, snoozes, shown alarms and nudges', (tester) async {
    final fakes = await start(tester, clock: TestClock(DateTime(2026, 10, 21, 9)));
    await deleteStopsRemindersFlow(tester, fakes);
    await stop(tester);
  });

  testWidgets('finishing today clears the reminders on screen and snoozed', (tester) async {
    final fakes = await start(tester, clock: TestClock(DateTime(2026, 10, 21, 9)));
    await doneClearsRemindersFlow(tester, fakes);
    await stop(tester);
  });

  testWidgets('alarms: strict challenge, re-ring, emergency exit, snooze', (tester) async {
    final clock = TestClock(DateTime(2026, 10, 21, 9));
    final fakes = await start(tester, clock: clock);
    await alarmFlow(tester, fakes, advance: (d) => clock.now = clock.now.add(d));
    await stop(tester);
  });

  testWidgets('nudges: enable, open work, unlock, usage access, apps', (tester) async {
    await run(
      tester,
      (f) => nudgesFlow(
        tester,
        f,
        waitPush: () async {
          await tester.pump(const Duration(seconds: 1));
          await settle(tester);
        },
      ),
      // The sample plans skip some weekdays; a fixed Wednesday keeps all four open.
      clock: TestClock(DateTime(2026, 10, 21, 9)),
    );
  });

  testWidgets('links from nudges and other apps open goals and start work', (tester) async {
    final fakes = await start(tester, listenForIntents: true);
    await tapKey(tester, 'empty-samples');

    // As MainActivity does when a link arrives while the app runs.
    Future<void> send(String link) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'app.getonit/intents',
        const StandardMethodCodec().encodeMethodCall(MethodCall('onText', link)),
        (_) {},
      );
      await settle(tester);
    }

    await send('getonit://goal/water');
    expect(find.widgetWithText(AppBar, 'Drink water'), findsOneWidget);
    await goBack(tester);

    final action = jsonEncode({
      'type': 'open_goal',
      'params': {'goalId': 'meditate'},
    });
    await send('getonit://action?json=${Uri.encodeComponent(action)}');
    expect(find.widgetWithText(AppBar, 'Meditate 10 min'), findsOneWidget, reason: 'a widget "open" button');
    await goBack(tester);

    await send('getonit://start/stanford-cs229');
    expect(fakes.launched.single.toString(), 'https://www.youtube.com/watch?v=jGwO_UgTS7I&t=0s');
    await stop(tester);
  });

  testWidgets('widgets: the app keeps the widget trees current', (tester) async {
    await run(
      tester,
      (f) => widgetsFlow(
        tester,
        f,
        waitPush: () async {
          await tester.pump(const Duration(seconds: 1));
          await settle(tester);
        },
      ),
    );
  });

  testWidgets('make a plan with any AI: copy the prompt, paste the answer', (tester) async {
    await run(tester, (f) => askAiFlow(tester, f));
  });

  testWidgets('change a plan with AI: the update keeps progress', (tester) async {
    await run(tester, (f) => editAiFlow(tester, f));
  });

  testWidgets('a shared clean plan is added at once and its page opens', (tester) async {
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
    await waitFor(tester, find.byKey(const ValueKey('import-done')));
    expect(find.byKey(const ValueKey('import-confirm')), findsNothing);
    expect(find.widgetWithText(AppBar, 'Drink water'), findsOneWidget);
    await stop(tester);
  });

  testWidgets('a plan shared while the import screen is open replaces it with the plan page', (tester) async {
    await start(tester, listenForIntents: true);
    await openPasteScreen(tester);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.getonit/intents',
      const StandardMethodCodec().encodeMethodCall(MethodCall('onText', await sampleText('habit-water.getonit.json'))),
      (_) {},
    );
    await waitFor(tester, find.byKey(const ValueKey('import-done')));
    expect(find.widgetWithText(AppBar, 'Drink water'), findsOneWidget);
    expect(find.byKey(const ValueKey('import-text')), findsNothing, reason: 'no empty import screen is left behind');
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
