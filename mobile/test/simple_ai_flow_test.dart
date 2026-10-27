import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/data/database.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  late AppDatabase db;
  late Fakes fakes;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    fakeClipboard(tester.binding.defaultBinaryMessenger);
    rootBundle.clear();
    db = memoryDatabase();
    addTearDown(db.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
    });
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
  }

  Future<void> resume(WidgetTester tester) async {
    // The full path: some listeners check that no state is skipped.
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await settle(tester);
  }

  Future<String> answer() async =>
      'Here is your plan.\n\n```json\n${await sampleText('habit-water.getonit.json')}\n```\n\nEnjoy.';

  final found = find.byKey(const ValueKey('plan-found'));

  setUp(() => fakes = Fakes()..planFinder = true);

  testWidgets('the 3 steps: Open ChatGPT and Open Claude copy the prompt and open the chat', (tester) async {
    await open(tester);
    await tapKey(tester, 'empty-ask');
    expect(find.text('Say what you want'), findsOneWidget);
    expect(find.text('Ask your AI'), findsOneWidget);
    expect(find.text('Bring the plan back'), findsOneWidget);
    await tapText(tester, 'Drink 8 glasses of water a day');
    await tapKey(tester, 'ask-chatgpt');
    expect(fakes.launched.last.toString(), 'https://chatgpt.com/');
    expect((await Clipboard.getData('text/plain'))!.text, contains('Drink 8 glasses of water a day'));
    await tapKey(tester, 'ask-claude');
    expect(fakes.launched.last.toString(), 'https://claude.ai/new');
    final launches = fakes.launched.length;
    await tapKey(tester, 'ask-copy');
    expect(fakes.launched.length, launches, reason: 'Copy prompt only opens nothing');
  });

  testWidgets('back from the AI chat: "Plan found" opens the preview, once per answer', (tester) async {
    await open(tester);
    await tapKey(tester, 'empty-ask');
    await tapText(tester, 'Drink 8 glasses of water a day');
    await tapKey(tester, 'ask-chatgpt');

    // Still the prompt in the clipboard: its example plan is not offered.
    await resume(tester);
    expect(found, findsNothing);

    await Clipboard.setData(ClipboardData(text: await answer()));
    await resume(tester);
    expect(found, findsOneWidget);
    expect(find.text('Plan found: Drink water'), findsOneWidget);
    await tapKey(tester, 'plan-found-open');
    await waitFor(tester, find.byKey(const ValueKey('import-confirm')));
    expect(find.text('8 glasses per day'), findsOneWidget);
    await tapKey(tester, 'import-confirm');
    expect(find.text('Drink water'), findsOneWidget);

    // The same answer again: not offered twice.
    await resume(tester);
    expect(found, findsNothing);
  });

  testWidgets('"Not now" shows the same answer only once; other text is ignored', (tester) async {
    await open(tester);
    await tapKey(tester, 'empty-ask');
    await tapKey(tester, 'ask-chatgpt');
    await Clipboard.setData(const ClipboardData(text: 'Just some words, no plan here.'));
    await resume(tester);
    expect(found, findsNothing);
    await Clipboard.setData(ClipboardData(text: await answer()));
    await resume(tester);
    expect(found, findsOneWidget);
    await tapText(tester, 'Not now');
    await resume(tester);
    expect(found, findsNothing);
  });

  testWidgets('without starting the AI flow, the clipboard is not read on return', (tester) async {
    await open(tester);
    await Clipboard.setData(ClipboardData(text: await answer()));
    await resume(tester);
    expect(found, findsNothing);
  });

  testWidgets('"I copied the answer" goes straight to the preview', (tester) async {
    await open(tester);
    await tapKey(tester, 'empty-ask');
    await tapKey(tester, 'ask-chatgpt');
    await Clipboard.setData(ClipboardData(text: await answer()));
    // The "Prompt copied" message covers the bottom for a few seconds.
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    await tapKey(tester, 'ask-import');
    await waitFor(tester, find.byKey(const ValueKey('import-confirm')));
    expect(find.text('8 glasses per day'), findsOneWidget);
  });

  testWidgets('the import screen checks a pasted answer by itself', (tester) async {
    await open(tester);
    await tapKey(tester, 'empty-import');
    await tester.enterText(find.byKey(const ValueKey('import-text')), await answer());
    await tester.pump(const Duration(seconds: 1));
    await waitFor(tester, find.byKey(const ValueKey('import-confirm')));
    expect(find.text('8 glasses per day'), findsOneWidget);
  });

  testWidgets('first time: the how-to video opens once; Skip closes it; it falls back to text', (tester) async {
    fakes.howToAutoShow = true;
    await open(tester);
    await tapKey(tester, 'empty-ask');
    await waitFor(tester, find.byKey(const ValueKey('howto-skip')));
    // No video player in host tests: the steps in words take its place.
    await waitFor(tester, find.byKey(const ValueKey('howto-fallback')));
    expect(find.text('Bring the plan back'), findsWidgets);
    expect(find.byKey(const ValueKey('howto-got-it')), findsOneWidget);
    await tapKey(tester, 'howto-skip');
    expect(find.byKey(const ValueKey('howto-skip')), findsNothing);
    expect(find.text('Ask your AI'), findsOneWidget);

    await goBack(tester);
    await tapKey(tester, 'empty-ask');
    expect(find.byKey(const ValueKey('howto-skip')), findsNothing, reason: 'shown only once');

    // "Watch how" plays it again at any time, without Skip.
    await tapKey(tester, 'ask-howto');
    await waitFor(tester, find.byKey(const ValueKey('howto-fallback')));
    expect(find.byKey(const ValueKey('howto-skip')), findsNothing);
  });
}
