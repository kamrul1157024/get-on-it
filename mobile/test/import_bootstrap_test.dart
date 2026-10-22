import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/features/import/import_screen.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  testWidgets('a plan shared while the app starts waits for the built-in templates', (tester) async {
    rootBundle.clear();
    final db = memoryDatabase();
    addTearDown(db.close);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    final plan = await sampleText('habit-water.getonit.json');
    // The import screen opens straight away, as for a share at app start:
    // nothing has installed the built-in templates yet.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: ImportScreen(initialText: plan)),
      ),
    );
    await waitFor(tester, find.byKey(const ValueKey('import-confirm')));
    expect(find.byKey(const ValueKey('import-errors')), findsNothing);
    expect(find.textContaining('is not installed'), findsNothing);
    expect(find.text('8 glasses per day'), findsOneWidget);
  });
}
