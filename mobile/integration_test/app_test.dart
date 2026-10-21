import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
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
  }) async {
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    final fakes = Fakes();
    await tester.pumpWidget(buildTestApp(db: db, pdfPicker: pdfPicker, fakes: realPlayer ? null : fakes));
    await waitFor(tester, find.text('No goals yet'));
    return fakes;
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> run(WidgetTester tester, Future<void> Function(Fakes) flow) async {
    final fakes = await start(tester);
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

  testWidgets('the real YouTube player opens', (tester) async {
    await start(tester, realPlayer: true);
    await tapKey(tester, 'empty-samples');
    await tester.tap(find.text('▶ Resume 0:00'));
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
