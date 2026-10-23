import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/data/repository.dart';
import 'package:getonit/features/nudges/nudges.dart';
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

  /// The permission popup alone: the strength step already done.
  Future<void> strengthDone() => Repository(db).setSetting('setup.strengthAsked', 'true');

  final prompt = find.byKey(const ValueKey('permission-prompt'));
  Finder row(String id) => find.byKey(ValueKey('permission:$id'));

  testWidgets('first start: every missing permission, each optional; allowed ones get a check', (tester) async {
    await setUpApp(tester);
    await strengthDone();
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
    // Google Play's prominent disclosure comes before the steps.
    expect(find.byKey(const ValueKey('usage-disclosure')), findsOneWidget);
    await tapKey(tester, 'disclosure-agree');
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
    await strengthDone();
    await open(tester);
    await tester.tapAt(const Offset(5, 5)); // outside the dialog, like the back button
    await settle(tester);
    expect(prompt, findsNothing);
    await open(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('nothing to ask: no popup', (tester) async {
    await setUpApp(tester);
    await strengthDone();
    fakes.notifications.permissionsGranted = const ReminderPermissions();
    fakes.nudges.usageAccess = true;
    await open(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('a permission added in a later version shows on its own', (tester) async {
    await setUpApp(tester);
    await strengthDone();
    fakes.shownPermissions.ids = {'notifications', 'exactAlarms', 'fullScreen'};
    await open(tester);
    expect(prompt, findsOneWidget);
    expect(row('usageAccess'), findsOneWidget);
    expect(row('notifications'), findsNothing);
    await tapKey(tester, 'permission-done');
  });

  testWidgets('a restored database does not stop the popup on a new phone', (tester) async {
    // The database (with every setting) came back from Android's backup; the
    // phone-only list of shown permissions did not.
    await setUpApp(tester);
    await strengthDone();
    await Repository(db).setSetting('permissions.shown', 'notifications,exactAlarms,fullScreen,usageAccess');
    await open(tester);
    expect(prompt, findsOneWidget);
    await tapKey(tester, 'permission-done');
  });

  testWidgets('the update dialog waits for the permission popup', (tester) async {
    await setUpApp(tester);
    await strengthDone();
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

  final strength = find.byKey(const ValueKey('strength-choice'));

  testWidgets('first start asks how hard to push, once; the choice goes to the nudges', (tester) async {
    await setUpApp(tester);
    fakes.notifications.permissionsGranted = const ReminderPermissions();
    fakes.nudges.usageAccess = true;
    await open(tester);
    expect(strength, findsOneWidget);
    expect(
      tester.widget<RadioGroup<NudgeStrength>>(find.byType(RadioGroup<NudgeStrength>)).groupValue,
      NudgeStrength.firm,
    );
    await tapKey(tester, 'strength:hard');
    await tapKey(tester, 'strength-continue');
    // Push me hard needs one more permission: the stop screen.
    expect(prompt, findsOneWidget);
    expect(row('overlay'), findsOneWidget);
    await tapKey(tester, 'permission-allow:overlay');
    expect(find.byKey(const ValueKey('overlay-disclosure')), findsOneWidget);
    await tapKey(tester, 'disclosure-agree');
    expect(find.byKey(const ValueKey('overlay-help')), findsOneWidget);
    await tapKey(tester, 'overlay-open-settings');
    await tapKey(tester, 'overlay-close');
    expect(find.byKey(const ValueKey('permission-ok:overlay')), findsOneWidget);
    await tapKey(tester, 'permission-done');
    expect((await Repository(db).settings())['nudges.strength'], 'hard');
    await waitFor(tester, find.byType(Scaffold));
    expect(fakes.nudges.configs.where((c) => c['strength'] == 'hard'), isNotEmpty);

    await open(tester);
    expect(strength, findsNothing);
    expect(prompt, findsNothing);
  });

  testWidgets('skipping the strength step keeps Firm, and no stop-screen permission', (tester) async {
    await setUpApp(tester);
    fakes.nudges.usageAccess = true;
    await open(tester);
    expect(strength, findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect((await Repository(db).settings())['nudges.strength'], 'firm');
    expect(row('overlay'), findsNothing);
    await tapKey(tester, 'permission-done');
    await open(tester);
    expect(strength, findsNothing);
  });

  testWidgets('Settings changes the strength; the limits text follows it', (tester) async {
    await setUpApp(tester);
    fakes.permissionPrompt = false;
    await open(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tapKey(tester, 'nudges-enabled');
    expect(find.text('At most one nudge every 2 h, and 4 a day.'), findsOneWidget);
    await tester.tap(find.text('Gentle'));
    await waitFor(tester, find.text('At most one nudge every 3 h, and 2 a day.'));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(fakes.nudges.last['strength'], 'gentle');
    await tester.tap(find.text('Hard'));
    await waitFor(tester, find.byKey(const ValueKey('nudges-overlay')));
    expect(find.text('At most one nudge every 20 min, and 12 a day.'), findsOneWidget);
  });

  testWidgets('usage access asks for consent first; "Not now" asks for nothing', (tester) async {
    await setUpApp(tester);
    await strengthDone();
    await open(tester);
    await tapKey(tester, 'permission-allow:usageAccess');
    expect(find.byKey(const ValueKey('usage-disclosure')), findsOneWidget);
    expect(find.textContaining('never sends it anywhere'), findsOneWidget);
    await tapKey(tester, 'disclosure-not-now');
    expect(find.byKey(const ValueKey('usage-help')), findsNothing);
    expect(fakes.nudges.usageAccess, false);
    expect(fakes.nudges.appDetailsOpened, 0);
    await tapKey(tester, 'permission-done');
  });
}
