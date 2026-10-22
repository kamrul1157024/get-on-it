import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';
import 'package:getonit/features/reminders/gateway.dart';

import 'support/app_harness.dart';
import 'support/flows.dart';

void main() {
  late AppDatabase db;
  late Fakes fakes;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(buildTestApp(db: db, fakes: fakes));
    await settle(tester);
  }

  Future<void> setUpApp(WidgetTester tester) async {
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
    fakes = Fakes()..permissionPrompt = true;
  }

  final prompt = find.byKey(const ValueKey('permission-prompt'));
  Finder row(String id) => find.byKey(ValueKey('permission:$id'));

  testWidgets('first start: every missing permission, each optional; allowed ones get a check', (tester) async {
    await setUpApp(tester);
    await open(tester);
    expect(prompt, findsOneWidget);
    for (final id in ['notifications', 'exactAlarms', 'fullScreen', 'usageAccess']) {
      expect(row(id), findsOneWidget, reason: id);
    }

    await tapKey(tester, 'permission-allow:notifications');
    expect(fakes.notifications.permissionsGranted.notifications, true);
    expect(find.byKey(const ValueKey('permission-ok:notifications')), findsOneWidget);

    // Usage access is allowed on a settings page; the row updates on return.
    await tapKey(tester, 'permission-allow:usageAccess');
    // Steps first: Android 13+ blocks usage access for downloaded APKs until
    // restricted settings are allowed in App info.
    expect(find.byKey(const ValueKey('usage-help')), findsOneWidget);
    await tapKey(tester, 'usage-open-app-info');
    expect(fakes.nudges.appDetailsOpened, 1);
    await tapKey(tester, 'usage-open-settings');
    await tapKey(tester, 'usage-close');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.byKey(const ValueKey('permission-ok:usageAccess')), findsOneWidget);

    // The other two are skipped.
    await tapKey(tester, 'permission-done');
    expect(prompt, findsNothing);

    // Skipped ones are not asked again.
    await open(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('closing at once skips everything, for good', (tester) async {
    await setUpApp(tester);
    await open(tester);
    await tester.tapAt(const Offset(5, 5)); // outside the dialog, like the back button
    await settle(tester);
    expect(prompt, findsNothing);
    await open(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('nothing to ask: no popup', (tester) async {
    await setUpApp(tester);
    fakes.notifications.permissionsGranted = const ReminderPermissions();
    fakes.nudges.usageAccess = true;
    await open(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('a permission added in a later version shows on its own', (tester) async {
    await setUpApp(tester);
    await Repository(db).setSetting('permissions.shown', 'notifications,exactAlarms,fullScreen');
    await open(tester);
    expect(prompt, findsOneWidget);
    expect(row('usageAccess'), findsOneWidget);
    expect(row('notifications'), findsNothing);
    await tapKey(tester, 'permission-done');
  });

  testWidgets('the update dialog waits for the permission popup', (tester) async {
    await setUpApp(tester);
    fakes.updates
      ..version = '0.3.0'
      ..releases = [
        {'tag_name': 'v0.3.1', 'body': 'Fixes', 'assets': const []},
      ];
    await open(tester);
    expect(prompt, findsOneWidget);
    expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
    await tapKey(tester, 'permission-done');
    expect(find.byKey(const ValueKey('update-dialog')), findsOneWidget);
    await tapKey(tester, 'update-later');
  });
}
