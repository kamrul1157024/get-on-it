import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getonit/actions/action_router.dart';
import 'package:getonit/app/app.dart';
import 'package:getonit/app/providers.dart';
import 'package:getonit/data/database.dart';
import 'package:getonit/features/drive/drive_account.dart';
import 'package:getonit/features/drive/drive_controller.dart';
import 'package:getonit/features/drive/remote_store.dart';
import 'package:getonit/features/player/video_backend.dart';
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

  @override
  Future<(String, String?)?> launchTap() async => null;

  @override
  Future<void> schedule(PlannedReminder r, {DateTime? at, bool snoozed = false}) async =>
      scheduled[r.id] = (r, at ?? r.localTime);

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> pendingIds() async => scheduled.keys.toSet();

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

/// Records what the app did outside itself.
class Fakes {
  final launched = <Uri>[];
  final videos = <FakeVideo>[];
  final drive = MemoryStore();
  final notifications = FakeGateway();
  late final driveAccount = FakeDriveAccount(drive);

  FakeVideo get video => videos.last;
}

/// The whole app on a fresh in-memory database. Used by the host widget tests
/// and by the on-device e2e tests.
Widget buildTestApp({
  required AppDatabase db,
  TestClock? clock,
  Fakes? fakes,
  Future<String?> Function(String goalId)? pdfPicker,
  bool listenForIntents = false,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(db),
    if (clock != null) wallClockProvider.overrideWithValue(clock.call),
    if (pdfPicker != null) pdfPickerProvider.overrideWithValue(pdfPicker),
    if (fakes != null) ...[
      externalLauncherProvider.overrideWithValue((url) async => fakes.launched.add(url)),
      driveAccountProvider.overrideWithValue(fakes.driveAccount),
      reminderGatewayProvider.overrideWithValue(fakes.notifications),
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
