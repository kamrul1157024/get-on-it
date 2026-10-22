import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  Future<Fakes> openSettings(WidgetTester tester, {required bool driveConfigured}) async {
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
    final fakes = Fakes()..driveConfigured = driveConfigured;
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    return fakes;
  }

  testWidgets('without a Google Cloud client id, Settings explains Android backup', (tester) async {
    final fakes = await openSettings(tester, driveConfigured: false);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('backup-section')), 300);
    expect(find.text('Connect Google Drive'), findsNothing);
    expect(find.textContaining('backs up your goals and progress to your Google account'), findsOneWidget);
    await tapKey(tester, 'backup-open-settings');
    expect(fakes.backupSettingsOpened, 1);
  });

  testWidgets('with a client id, Settings shows the Drive section instead', (tester) async {
    await openSettings(tester, driveConfigured: true);
    await tester.scrollUntilVisible(find.text('Connect Google Drive'), 300);
    expect(find.text('Connect Google Drive'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-section')), findsNothing);
  });
}
