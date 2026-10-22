import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/features/permissions/permission_prompt.dart';
import 'package:getonit/features/update/update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:getonit/actions/action_router.dart';
import 'package:getonit/app/app.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/features/drive/drive_account.dart';
import 'package:getonit/features/drive/drive_controller.dart';
import 'package:getonit/features/drive/remote_store.dart';
import 'package:getonit/features/nudges/nudges.dart';
import 'package:getonit/features/nudges/wasted_time.dart';
import 'package:getonit/features/player/video_backend.dart';
import 'package:getonit/features/widgets/home_widgets.dart';
import 'package:getonit/features/reminders/gateway.dart';
import 'package:getonit/features/reminders/planner.dart';
import 'package:getonit/features/reminders/reminders_controller.dart';

/// A controllable clock shared by the app and the test.
class TestClock {
  TestClock(this.now);

  DateTime now;

  DateTime call() => now;
}

/// A player the test drives: it reports the positions the test pushes.
class FakeVideo implements VideoBackend {
  FakeVideo(this.videoId, this.startSec);

  final String videoId;
  final int startSec;
  final _positions = StreamController<double>.broadcast();
  final _stops = StreamController<void>.broadcast();
  final _problems = StreamController<VideoProblem>.broadcast();
  bool disposed = false;

  void play(double sec) => _positions.add(sec);
  void pause() => _stops.add(null);
  void fail(VideoProblem p) => _problems.add(p);

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('fake-player:$videoId'),
    height: 200,
    child: Center(child: Text('Fake player $videoId from $startSec')),
  );

  @override
  Stream<double> get positions => _positions.stream;

  @override
  Stream<void> get stops => _stops.stream;

  @override
  Stream<VideoProblem> get problems => _problems.stream;

  @override
  void dispose() => disposed = true;
}

/// A Google account whose Drive is a [MemoryStore].
class FakeDriveAccount implements DriveAccount {
  FakeDriveAccount(this.store);

  final MemoryStore store;
  bool signedIn = false;

  @override
  Future<DriveConnection?> restore() async => signedIn ? DriveConnection('test@example.com', store) : null;

  @override
  Future<DriveConnection> connect() async {
    signedIn = true;
    return DriveConnection('test@example.com', store);
  }

  @override
  Future<void> disconnect() async => signedIn = false;
}

/// The phone's notification system, in memory.
class FakeGateway implements NotificationGateway {
  final scheduled = <int, (PlannedReminder, DateTime)>{};
  final cancelled = <int>[];
  ReminderTap? _onTap;
  var permissionsGranted = const ReminderPermissions(notifications: false, exactAlarms: false, fullScreen: false);

  /// Simulates the user tapping a reminder, or one of its buttons.
  void tap(PlannedReminder r, {String? action}) => _onTap!(r.payload, action);

  Iterable<PlannedReminder> get reminders => scheduled.values.map((e) => e.$1);

  @override
  Future<void> init(ReminderTap onTap) async => _onTap = onTap;

  /// The phone's time zone; a test changes it to simulate travel.
  String zone = 'Europe/Berlin';
  String _seenZone = 'Europe/Berlin';
  int scheduleCalls = 0;
  int zoneChanges = 0;

  /// How often the reminders were planned (each plan reads the pending ids).
  int plans = 0;

  @override
  Future<bool> refreshTimeZone() async {
    if (zone == _seenZone) return false;
    _seenZone = zone;
    zoneChanges++;
    return true;
  }

  @override
  Future<(String, String?)?> launchTap() async => null;

  @override
  Future<void> schedule(PlannedReminder r, {DateTime? at, bool snoozed = false}) async {
    scheduleCalls++;
    scheduled[r.id] = (r, at ?? r.localTime);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> pendingIds() async {
    plans++;
    return scheduled.keys.toSet();
  }

  @override
  Future<ReminderPermissions> permissions() async => permissionsGranted;

  @override
  Future<void> requestNotifications() async => permissionsGranted = ReminderPermissions(
    notifications: true,
    exactAlarms: permissionsGranted.exactAlarms,
    fullScreen: permissionsGranted.fullScreen,
  );

  @override
  Future<void> requestExactAlarms() async => permissionsGranted = ReminderPermissions(
    notifications: permissionsGranted.notifications,
    exactAlarms: true,
    fullScreen: permissionsGranted.fullScreen,
  );

  @override
  Future<void> requestFullScreen() async => permissionsGranted = ReminderPermissions(
    notifications: permissionsGranted.notifications,
    exactAlarms: permissionsGranted.exactAlarms,
    fullScreen: true,
  );
}

/// The native nudge service, in memory.
class FakeNudgeBridge implements NudgeBridge {
  final configs = <Map<String, Object?>>[];
  bool usageAccess = false;

  Map<String, Object?> get last => configs.last;

  @override
  Future<void> configure(Map<String, Object?> config) async => configs.add(config);

  @override
  Future<({bool running, bool usageAccess})> status() async =>
      (running: configs.isNotEmpty && last['enabled'] == true, usageAccess: usageAccess);

  @override
  Future<void> openUsageAccessSettings() async => usageAccess = true;

  int appDetailsOpened = 0;

  @override
  Future<void> openAppDetails() async => appDetailsOpened++;

  /// What the phone reports as lost time, per period.
  var usage = <LostPeriod, List<AppUsage>>{};
  List<String>? lastExcluded;
  bool overlay = false;

  @override
  Future<Map<LostPeriod, List<AppUsage>>> lostTime(List<String> excluded) async {
    lastExcluded = excluded;
    if (!usageAccess) return const {};
    return {
      for (final e in usage.entries)
        e.key: [
          for (final u in e.value)
            if (!excluded.contains(u.package)) u,
        ],
    };
  }

  @override
  Future<bool> canDrawOverlays() async => overlay;

  @override
  Future<void> openOverlaySettings() async => overlay = true;

  @override
  Future<List<({String package, String label})>> listApps() async => const [
    (package: 'com.android.chrome', label: 'Chrome'),
    (package: 'com.instagram.android', label: 'Instagram'),
    (package: 'com.google.android.youtube', label: 'YouTube'),
  ];
}

/// The native widgets, in memory.
class FakeWidgetBridge implements WidgetBridge {
  final data = <String, String>{};
  var refreshes = 0;

  @override
  Future<void> save(Map<String, String> d) async => data.addAll(d);

  @override
  Future<void> refresh() async => refreshes++;
}

/// Records what the app did outside itself.
class Fakes {
  final launched = <Uri>[];
  final videos = <FakeVideo>[];
  final drive = MemoryStore();
  final notifications = FakeGateway();
  final nudges = FakeNudgeBridge();
  final widgets = FakeWidgetBridge();
  late final driveAccount = FakeDriveAccount(drive);
  final updates = FakeUpdates();

  /// The first-start permission popup. Off unless a test is about it.
  bool permissionPrompt = false;

  FakeVideo get video => videos.last;
}

/// GitHub's releases list and the installer, for the update flow. "dev" is
/// what a debug build reports: no check on start.
class FakeUpdates implements ApkInstaller {
  String version = 'dev';
  List<Map<String, Object?>> releases = const [];
  int requests = 0;
  final installed = <String>[];

  http.Client get client => MockClient((req) async {
    requests++;
    return http.Response(jsonEncode(releases), 200);
  });

  @override
  Future<void> install(String url, {void Function(double progress)? onProgress}) async {
    onProgress?.call(1);
    installed.add(url);
  }
}

/// The whole app on a fresh in-memory database. Used by the host widget tests
/// and by the on-device e2e tests.
Widget buildTestApp({
  required AppDatabase db,
  TestClock? clock,
  Fakes? fakes,
  Future<String?> Function(String goalId)? pdfPicker,
  bool listenForIntents = false,
  bool realNudges = false,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(db),
    if (clock != null) wallClockProvider.overrideWithValue(clock.call),
    if (pdfPicker != null) pdfPickerProvider.overrideWithValue(pdfPicker),
    if (fakes == null) permissionPromptEnabledProvider.overrideWith((ref) => false),
    if (fakes != null) ...[
      externalLauncherProvider.overrideWithValue((url) async => fakes.launched.add(url)),
      driveAccountProvider.overrideWithValue(fakes.driveAccount),
      installedVersionProvider.overrideWith((ref) => fakes.updates.version),
      permissionPromptEnabledProvider.overrideWith((ref) => fakes.permissionPrompt),
      httpClientProvider.overrideWithValue(fakes.updates.client),
      apkInstallerProvider.overrideWithValue(fakes.updates),
      reminderGatewayProvider.overrideWithValue(fakes.notifications),
      if (!realNudges) nudgeBridgeProvider.overrideWithValue(fakes.nudges),
      widgetBridgeProvider.overrideWithValue(fakes.widgets),
      autoBackupDelayProvider.overrideWithValue(const Duration(seconds: 2)),
      videoBackendProvider.overrideWithValue((id, start) {
        final v = FakeVideo(id, start);
        fakes.videos.add(v);
        return v;
      }),
    ],
  ],
  child: GetOnItApp(listenForIntents: listenForIntents),
);

AppDatabase memoryDatabase() =>
    AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));

/// Host tests have no system clipboard; this stands in for it.
void fakeClipboard(TestDefaultBinaryMessenger messenger) {
  String? text;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        text = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return text == null ? null : {'text': text};
      case 'Clipboard.hasStrings':
        return {'value': text != null};
    }
    return null;
  });
}
