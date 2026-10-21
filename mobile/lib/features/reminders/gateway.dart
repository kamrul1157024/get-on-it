import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'planner.dart';

/// Android checks that no plugin offers (MainActivity.kt).
const systemChannel = MethodChannel('app.getonit/system');

/// A tap on a reminder, or on one of its buttons (`done`, `snooze`).
typedef ReminderTap = void Function(String payload, String? action);

class ReminderPermissions {
  const ReminderPermissions({this.notifications = true, this.exactAlarms = true, this.fullScreen = true});

  final bool notifications;
  final bool exactAlarms;
  final bool fullScreen;
}

/// The phone's notification system. Tests use a fake.
abstract class NotificationGateway {
  Future<void> init(ReminderTap onTap);

  /// The reminder that started the app, if any.
  Future<(String, String?)?> launchTap();

  Future<void> schedule(PlannedReminder r, {DateTime? at, bool snoozed = false});

  Future<void> cancel(int id);

  Future<Set<int>> pendingIds();

  Future<ReminderPermissions> permissions();

  Future<void> requestNotifications();

  Future<void> requestExactAlarms();

  Future<void> requestFullScreen();
}

/// flutter_local_notifications on Android.
class LocalNotificationsGateway implements NotificationGateway {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> init(ReminderTap onTap) async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (e) {
      debugPrint('Time zone not found, using UTC: $e');
    }
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) onTap(r.payload!, r.actionId);
      },
    );
    _ready = true;
  }

  @override
  Future<(String, String?)?> launchTap() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    final r = d?.notificationResponse;
    if (d?.didNotificationLaunchApp != true || r?.payload == null) return null;
    return (r!.payload!, r.actionId);
  }

  static const _done = AndroidNotificationAction('done', 'Done', showsUserInterface: true, cancelNotification: true);
  static const _snooze = AndroidNotificationAction(
    'snooze',
    'Snooze',
    showsUserInterface: true,
    cancelNotification: true,
  );

  AndroidNotificationDetails _details(ReminderLevel level, {required bool canSnooze}) => switch (level) {
    ReminderLevel.notification => const AndroidNotificationDetails(
      'reminders',
      'Reminders',
      channelDescription: 'Reminders for your goals',
      importance: Importance.high,
      priority: Priority.high,
      actions: [_done],
    ),
    ReminderLevel.sticky => AndroidNotificationDetails(
      'reminders-sticky',
      'Persistent reminders',
      channelDescription: 'Reminders that stay until you act',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      actions: [_done, if (canSnooze) _snooze],
    ),
    ReminderLevel.alarm || ReminderLevel.strictAlarm => AndroidNotificationDetails(
      level == ReminderLevel.alarm ? 'alarms' : 'alarms-strict',
      level == ReminderLevel.alarm ? 'Alarms' : 'Strict alarms',
      channelDescription: 'Full-screen alarms for your goals',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      ongoing: true,
      autoCancel: false,
      // FLAG_INSISTENT: the sound repeats until the alarm is handled.
      additionalFlags: level == ReminderLevel.strictAlarm ? Int32List.fromList([4]) : null,
      actions: [if (canSnooze && level == ReminderLevel.alarm) _snooze],
    ),
  };

  @override
  Future<void> schedule(PlannedReminder r, {DateTime? at, bool snoozed = false}) async {
    final when = tz.TZDateTime.from(at ?? r.localTime, tz.local);
    final exact = await _android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      id: r.id,
      scheduledDate: when,
      title: r.title,
      body: r.body,
      payload: r.payload,
      notificationDetails: NotificationDetails(
        android: _details(r.level, canSnooze: !snoozed && r.step.maxSnoozes > 0),
      ),
      androidScheduleMode: exact
          ? (r.level.isAlarm ? AndroidScheduleMode.alarmClock : AndroidScheduleMode.exactAllowWhileIdle)
          : AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<Set<int>> pendingIds() async => {for (final p in await _plugin.pendingNotificationRequests()) p.id};

  @override
  Future<ReminderPermissions> permissions() async {
    final a = _android;
    if (a == null) return const ReminderPermissions();
    return ReminderPermissions(
      notifications: await a.areNotificationsEnabled() ?? false,
      exactAlarms: await a.canScheduleExactNotifications() ?? false,
      fullScreen: await systemChannel.invokeMethod<bool>('canUseFullScreenIntent') ?? true,
    );
  }

  @override
  Future<void> requestNotifications() async => _android?.requestNotificationsPermission();

  @override
  Future<void> requestExactAlarms() async => _android?.requestExactAlarmsPermission();

  @override
  Future<void> requestFullScreen() async => _android?.requestFullScreenIntentPermission();
}
