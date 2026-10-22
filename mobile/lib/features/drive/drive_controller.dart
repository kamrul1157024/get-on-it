import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../reminders/gateway.dart' show systemChannel;
import 'backup.dart';
import 'drive_account.dart';

final driveAccountProvider = Provider<DriveAccount>((ref) => GoogleDriveAccount());

/// Whether this build can sign in to Google Drive. Without a Google Cloud
/// client id (docs/drive.md), Settings shows Android's own backup instead.
final driveConfiguredProvider = Provider<bool>((ref) => googleServerClientId.isNotEmpty);

/// Opens the phone's backup settings. Tests use a fake.
final openBackupSettingsProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => systemChannel.invokeMethod<void>('openBackupSettings'),
);

/// Delay between the last change and the automatic backup. Spec §13.3.
final autoBackupDelayProvider = Provider<Duration>((ref) => const Duration(seconds: 60));

class DriveState {
  const DriveState({this.connection, this.busy = false, this.lastBackupAt, this.message, this.error});

  final DriveConnection? connection;
  final bool busy;
  final DateTime? lastBackupAt;
  final String? message;
  final String? error;

  bool get connected => connection != null;

  DriveState copyWith({
    DriveConnection? connection,
    bool clearConnection = false,
    bool? busy,
    DateTime? lastBackupAt,
    String? message,
    String? error,
  }) => DriveState(
    connection: clearConnection ? null : (connection ?? this.connection),
    busy: busy ?? this.busy,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    message: message,
    error: error,
  );
}

final driveProvider = NotifierProvider<DriveController, DriveState>(DriveController.new);

class DriveController extends Notifier<DriveState> {
  StreamSubscription<void>? _changes;
  Timer? _debounce;

  @override
  DriveState build() {
    ref.onDispose(() {
      _changes?.cancel();
      _debounce?.cancel();
    });
    Future.microtask(_restoreSession);
    return const DriveState();
  }

  Future<void> _restoreSession() async {
    final repo = ref.read(repositoryProvider);
    final s = await repo.settings();
    final last = DateTime.tryParse(s['backup.lastAt'] ?? '');
    if (last != null) state = state.copyWith(lastBackupAt: last);
    if (s['backup.account'] == null) return;
    try {
      final c = await ref.read(driveAccountProvider).restore();
      if (c != null) _connected(c);
    } catch (_) {
      // Stay disconnected; the user can connect again.
    }
  }

  void _connected(DriveConnection c) {
    state = state.copyWith(connection: c);
    _changes?.cancel();
    _changes = ref.read(repositoryProvider).changes.listen((_) => _scheduleAuto());
  }

  void _scheduleAuto() {
    if (state.busy) return;
    _debounce?.cancel();
    _debounce = Timer(ref.read(autoBackupDelayProvider), () => backupNow(auto: true));
  }

  Future<String> _deviceId() async {
    final repo = ref.read(repositoryProvider);
    final id = (await repo.settings())['deviceId'];
    if (id != null) return id;
    final made = const Uuid().v4();
    await repo.setSetting('deviceId', made);
    return made;
  }

  Future<void> connect() async {
    state = state.copyWith(busy: true);
    try {
      final c = await ref.read(driveAccountProvider).connect();
      await ref.read(repositoryProvider).setSetting('backup.account', c.email);
      _connected(c);
      state = state.copyWith(busy: false, message: 'Connected as ${c.email}');
    } catch (e) {
      state = state.copyWith(busy: false, error: '$e');
    }
  }

  Future<BackupResult?> backupNow({bool auto = false}) async {
    final c = state.connection;
    if (c == null || state.busy) return null;
    state = state.copyWith(busy: true);
    try {
      // Writing the time is itself a change; ignore it for the auto timer.
      final repo = ref.read(repositoryProvider);
      final result = await BackupService(repo, c.store, await _deviceId()).backup();
      final now = ref.read(wallClockProvider)();
      await repo.setSetting('backup.lastAt', now.toIso8601String());
      _debounce?.cancel();
      state = state.copyWith(busy: false, lastBackupAt: now, message: auto ? null : 'Backed up $result');
      return result;
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Backup failed: $e');
      return null;
    }
  }

  Future<BackupResult?> restore() async {
    final c = state.connection;
    if (c == null || state.busy) return null;
    state = state.copyWith(busy: true);
    try {
      final result = await BackupService(ref.read(repositoryProvider), c.store, await _deviceId()).restore();
      _debounce?.cancel();
      state = state.copyWith(busy: false, message: 'Restored $result');
      return result;
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Restore failed: $e');
      return null;
    }
  }

  Future<void> deleteBackup() async {
    final c = state.connection;
    if (c == null) return;
    state = state.copyWith(busy: true);
    try {
      await c.store.deleteAll();
      await ref.read(repositoryProvider).setSetting('backup.lastAt', '');
      state = DriveState(connection: c, message: 'Backup deleted from Drive');
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Delete failed: $e');
    }
  }

  Future<void> disconnect() async {
    _changes?.cancel();
    _debounce?.cancel();
    try {
      await ref.read(driveAccountProvider).disconnect();
    } catch (_) {}
    final repo = ref.read(repositoryProvider);
    await repo.setSetting('backup.account', '');
    state = state.copyWith(clearConnection: true, message: 'Disconnected');
  }

  /// Backs up now if a change is waiting, for example when the app goes to
  /// the background.
  Future<void> flush() async {
    if (_debounce?.isActive ?? false) await backupNow(auto: true);
  }
}
