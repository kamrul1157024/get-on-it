import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:getonit/core/schema/documents.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';
import 'package:getonit/features/widgets/home_widgets.dart';
import 'package:home_widget/home_widget.dart';
import 'package:getonit/features/reminders/gateway.dart';
import 'package:getonit/features/reminders/planner.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../test/support/app_harness.dart';
import '../test/support/flows.dart';

/// End-to-end tests on a real Android device or emulator: real SQLite, real
/// asset loading, real rendering, and the real PDF engine.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Fakes> start(
    WidgetTester tester, {
    Future<String?> Function(String)? pdfPicker,
    bool realPlayer = false,
    bool realNudges = false,
    TestClock? clock,
  }) async {
    rootBundle.clear();
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
    await tester.pumpWidget(
      buildTestApp(
        db: db,
        pdfPicker: pdfPicker,
        fakes: realPlayer ? null : fakes,
        clock: clock,
        realNudges: realNudges,
      ),
    );
    await waitFor(tester, find.text('No goals yet'));
    return fakes;
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> run(WidgetTester tester, Future<void> Function(Fakes) flow, {TestClock? clock}) async {
    final fakes = await start(tester, clock: clock);
    await flow(fakes);
    await stop(tester);
  }

  testWidgets('player: resume, save positions, YouTube link, mark done', (tester) async {
    await run(tester, (f) => playerFlow(tester, f));
  });

  testWidgets('course screen: lecture list, task toggle, open task, delete', (tester) async {
    await run(tester, (f) => courseScreenFlow(tester, f));
  });

  testWidgets('book: mark today done', (tester) async {
    await run(tester, (_) => bookMarkTodayFlow(tester));
  });

  testWidgets('habits: check undo, avoid habit, checklist', (tester) async {
    await run(tester, (_) => moreHabitsFlow(tester));
  });

  testWidgets('import: paste button and copy errors for Claude', (tester) async {
    await run(tester, (_) => clipboardFlow(tester));
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
          final end = DateTime.now().add(const Duration(seconds: 10));
          while (DateTime.now().isBefore(end)) {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
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

  testWidgets('the real notification system schedules and cancels a reminder', (tester) async {
    final gw = LocalNotificationsGateway();
    await gw.init((_, _) {});
    final goal = GoalDoc({
      'kind': 'goal',
      'schemaVersion': '1.0',
      'id': 'e2e-reminder',
      'template': 'habit@1',
      'title': 'E2E reminder',
      'reminders': {'preset': 'strict', 'time': '19:00'},
      'data': {'mode': 'check'},
    });
    final steps = ladderOf(goal);
    final at = DateTime.now().add(const Duration(minutes: 30));
    for (var i = 0; i < steps.length; i++) {
      await gw.schedule(
        PlannedReminder(
          id: 900000 + i,
          goalId: goal.id,
          day: 0,
          minuteOfDay: 0,
          step: steps[i],
          title: 'E2E reminder',
          body: 'level ${steps[i].level.wire}',
        ),
        at: at.add(Duration(minutes: i)),
      );
    }
    final pending = await gw.pendingIds();
    expect(pending, containsAll([900000, 900001, 900002, 900003]), reason: 'all four levels are accepted by Android');
    for (var i = 0; i < steps.length; i++) {
      await gw.cancel(900000 + i);
    }
    expect((await gw.pendingIds()).intersection({900000, 900001, 900002, 900003}), isEmpty);
    final perms = await gw.permissions();
    debugPrint(
      'permissions: notifications=${perms.notifications} exact=${perms.exactAlarms} fullScreen=${perms.fullScreen}',
    );
  });

  testWidgets('nudges: enable, open work, unlock, usage access, apps', (tester) async {
    await run(
      tester,
      (f) => nudgesFlow(
        tester,
        f,
        waitPush: () async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          await settle(tester);
        },
      ),
      // The sample plans skip some weekdays; a fixed Wednesday keeps all four open.
      clock: TestClock(DateTime(2026, 10, 21, 9)),
    );
  });

  testWidgets('the real nudge service runs, nudges on unlock, and stops', (tester) async {
    // The sample plans skip some weekdays; a fixed Wednesday keeps all four open.
    await start(tester, realNudges: true, clock: TestClock(DateTime(2026, 10, 21, 9)));
    await tapKey(tester, 'empty-samples');
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tapKey(tester, 'nudges-enabled');
    Future<Map<String, Object?>> status() async =>
        await systemChannel.invokeMapMethod<String, Object?>('nudgeStatus') ?? const {};
    await waitUntil(() async => (await status())['running'] == true);
    expect(find.text('On. 4 goals still open today.'), findsOneWidget);

    final apps = await systemChannel.invokeListMethod<Map>('listApps');
    expect(apps, isNotEmpty);

    final nudge = await systemChannel.invokeMapMethod<String, Object?>('nudgeSimulate', {'trigger': 'unlock'});
    expect(nudge?['title'], 'Stanford CS229: Machine Learning');
    expect(nudge?['link'], 'getonit://start/stanford-cs229');
    final again = await systemChannel.invokeMapMethod<String, Object?>('nudgeSimulate', {'trigger': 'unlock'});
    expect(again, isNull, reason: 'at most one nudge every 2 hours');

    await tapKey(tester, 'nudges-enabled');
    await waitUntil(() async => (await status())['running'] == false);
    await goBack(tester);
    await stop(tester);
  });

  testWidgets('widgets: the app keeps the widget trees current', (tester) async {
    await run(
      tester,
      (f) => widgetsFlow(
        tester,
        f,
        waitPush: () async {
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 200));
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          await settle(tester);
        },
      ),
    );
  });

  testWidgets('a widget "+1" runs in the background against the real database', (tester) async {
    // Put a goal in the app's real database file.
    var db = AppDatabase();
    var repo = Repository(db);
    await repo.installTemplate(
      TemplateDoc((jsonDecode(await rootBundle.loadString('assets/templates/habit.json')) as Map).cast()),
      source: 'builtin',
    );
    await repo.deleteGoal('e2e-water');
    await repo.saveGoal(
      GoalDoc({
        'kind': 'goal',
        'schemaVersion': '1.0',
        'id': 'e2e-water',
        'template': 'habit@1',
        'title': 'E2E water',
        'data': {'mode': 'count', 'unit': 'glasses', 'target': 8},
      }),
    );
    await db.close();

    // As a tap on the widget's + button does.
    final action = jsonEncode({
      'type': 'log_progress',
      'params': {'goalId': 'e2e-water', 'delta': 1},
    });
    await widgetBackgroundCallback(Uri.parse('getonit://widget?json=${Uri.encodeComponent(action)}'));

    db = AppDatabase();
    repo = Repository(db);
    final events = (await repo.allEvents()).where((e) => e.goalId == 'e2e-water').toList();
    expect(events.single.payload, {'delta': 1});
    final tree = await HomeWidget.getWidgetData<String>('goal:e2e-water:medium');
    expect(tree, contains('1 / 8 glasses'), reason: 'the widget data was redrawn through home_widget');
    await repo.deleteGoal('e2e-water');
    await db.close();
  });

  testWidgets('make a plan with any AI: copy the prompt, paste the answer', (tester) async {
    await run(tester, (f) => askAiFlow(tester, f));
  });

  testWidgets('change a plan with AI: the update keeps progress', (tester) async {
    await run(tester, (f) => editAiFlow(tester, f));
  });

  testWidgets('the real YouTube player opens', skip: isCi, (tester) async {
    await start(tester, realPlayer: true);
    await importPlan(tester, await embeddableCourse());
    await tester.tap(find.text('▶ Start'));
    await waitFor(tester, find.text('Lecture 1: Introduction'));
    expect(find.byType(YoutubePlayer), findsOneWidget);
    await tester.pageBack();
    await waitFor(tester, find.text('Get On It'));
    await stop(tester);
  });

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

  testWidgets('book: link a PDF, open today\'s page, and the reader records it', (tester) async {
    final dir = await getTemporaryDirectory();
    final pdf = File('${dir.path}/e2e-book.pdf')..writeAsBytesSync(tinyPdf(3));
    await start(tester, pdfPicker: (_) async => pdf.path);

    await importPlan(
      tester,
      jsonEncode({
        'kind': 'goal',
        'schemaVersion': '1.0',
        'id': 'e2e-book',
        'template': 'book@1',
        'title': 'E2E book',
        'data': {
          'book': {'title': 'E2E book'},
          'source': {'kind': 'local_file'},
          'pages': {'start': 1, 'end': 3, 'perDay': 2},
        },
      }),
    );
    await tapText(tester, 'E2E book · Page 0 of 3');
    await tapText(tester, 'Select the PDF');
    expect(find.text('📖 Read p. 1–2'), findsOneWidget);
    await goBack(tester);

    // The Read button on the Today tile opens the reader at today's page.
    final tile = find.byKey(const ValueKey('goal-tile:e2e-book'));
    await tester.tap(find.descendant(of: tile, matching: find.text('Read')));
    await waitFor(tester, find.text('Today: p. 1–2'));
    // The reader records a page after 5 seconds on it.
    await waitFor(tester, find.text('Page 1 of 3'), timeout: const Duration(seconds: 30));

    // Turn to page 2: today's pages are complete.
    await tester.timedDrag(find.byType(PdfViewer), const Offset(0, -500), const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, find.text('Page 2 of 3'), timeout: const Duration(seconds: 30));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await goBack(tester);
    expect(find.descendant(of: tile, matching: find.text('✓ Today')), findsOneWidget);
    await stop(tester);
  });
}

/// Set by the CI workflow; skips tests that need YouTube online.
const isCi = bool.fromEnvironment('CI');

/// Waits with real time passing until [check] is true.
Future<void> waitUntil(Future<bool> Function() check, {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  fail('timed out after $timeout');
}

/// Pumps with real time passing until [finder] matches.
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  expect(finder, findsWidgets, reason: 'timed out after $timeout');
}

/// A valid PDF with [pages] pages, each showing its number.
List<int> tinyPdf(int pages) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < pages; i++) '${3 + i} 0 R'].join(' ')}] /Count $pages >>',
    for (var i = 0; i < pages; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
          '/Contents ${3 + pages + i} 0 R /Resources << /Font << /F1 ${3 + 2 * pages} 0 R >> >> >>',
    for (var i = 0; i < pages; i++)
      () {
        final stream = 'BT /F1 48 Tf 120 200 Td (${i + 1}) Tj ET';
        return '<< /Length ${stream.length} >>\nstream\n$stream\nendstream';
      }(),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}
