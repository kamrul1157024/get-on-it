import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/binding/resolver.dart';
import '../../core/time/day_clock.dart';
import 'gateway.dart';
import 'planner.dart';

final reminderGatewayProvider = Provider<NotificationGateway>((ref) => LocalNotificationsGateway());

/// Settings key that records the user's approval for one goal. Spec §11.5.
String reminderSettingKey(String goalId) => 'reminders.on.$goalId';

/// Snoozed and re-ring reminders use ids with this bit, so a plan sync does
/// not cancel them.
const snoozeBit = 0x40000000;

/// Text for a goal's reminder: the template's `nudge` surface, or a default
/// from the engine state.
(String, String) reminderText(GoalView view) {
  final nudge = view.template?.surface('nudge');
  if (nudge != null) {
    final title = resolve(nudge['title'], view.scope);
    final body = resolve(nudge['body'], view.scope);
    if (title is String && body is String && title.isNotEmpty) return (title, body);
  }
  final s = view.state;
  final next = s['next'] as Map?;
  final today = s['today'] as Map?;
  final body = next != null
      ? '${next['title']} · ${next['external'] == true ? 'Watch on YouTube' : next['remainingLabel']}'
      : today != null
      ? 'Read ${today['label']} · ${today['minutesLabel']}'
      : '${s['progressLabel'] ?? ''}';
  return (view.goal.title, body);
}

class RemindersState {
  const RemindersState({this.permissions = const ReminderPermissions(), this.planned = const []});

  final ReminderPermissions permissions;
  final List<PlannedReminder> planned;
}

final remindersProvider = NotifierProvider<RemindersController, RemindersState>(RemindersController.new);

class RemindersController extends Notifier<RemindersState> {
  Timer? _debounce;
  StreamSubscription<void>? _changes;
  bool _started = false;

  NotificationGateway get _gw => ref.read(reminderGatewayProvider);

  @override
  RemindersState build() {
    ref.onDispose(() {
      _debounce?.cancel();
      _changes?.cancel();
    });
    // A new day or a settings change (quiet hours, pause) changes the plan.
    ref.listen(currentDayProvider, (_, _) => scheduleSync());
    ref.listen(settingsProvider, (_, _) => scheduleSync());
    return const RemindersState();
  }

  /// Connects to the notification system. [onTap] receives reminder taps.
  Future<void> start(ReminderTap onTap) async {
    if (_started) return;
    _started = true;
    await _gw.init(onTap);
    _changes = ref.read(repositoryProvider).changes.listen((_) => scheduleSync());
    await refreshPermissions();
    await sync();
    final launch = await _gw.launchTap();
    if (launch != null) onTap(launch.$1, launch.$2);
  }

  /// After travel or a manual change, a 19:00 reminder must ring at 19:00 in
  /// the new zone, not at the old zone's instant.
  Future<void> refreshTimeZone() async {
    if (!_started) return;
    if (await _gw.refreshTimeZone()) await sync();
  }

  Future<void> refreshPermissions() async {
    state = RemindersState(permissions: await _gw.permissions(), planned: state.planned);
  }

  void scheduleSync() {
    if (!_started) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), sync);
  }

  /// Makes the scheduled notifications match the plan.
  Future<List<PlannedReminder>> sync() async {
    final repo = ref.read(repositoryProvider);
    final settings = await repo.settings();
    final goals = await repo.allGoals();
    final clock = ref.read(dayClockProvider);
    final now = ref.read(wallClockProvider)();
    final today = clock.dayOfDateTime(now);
    final inputs = <ReminderInput>[];
    for (final g in goals) {
      final view = ref.read(goalViewProvider(g.id));
      if (view == null) continue;
      final (title, body) = reminderText(view);
      inputs.add(
        ReminderInput(
          goal: view.goal,
          enabled: settings[reminderSettingKey(g.id)] == 'true',
          isDayComplete: (day) => day == today && view.state['todayComplete'] == true,
          title: title,
          body: body,
        ),
      );
    }
    final plan = planReminders(
      goals: inputs,
      rules: ReminderRules.fromSettings(settings),
      today: today,
      nowMinute: now.hour * 60 + now.minute,
    );
    final wanted = {for (final r in plan) r.id};
    final live = {for (final g in goals) g.id};
    bool doneToday(String goalId) => ref.read(goalViewProvider(goalId))?.state['todayComplete'] == true;
    // A reminder of a goal that is gone (deleted, or replaced by a restore)
    // or whose work is done today stops, snoozed or not. Other snoozed ones
    // stay: the user asked for them.
    bool over(String? goalId) => goalId != null && (!live.contains(goalId) || doneToday(goalId));
    for (final n in await _gw.pending()) {
      final snoozed = n.id & snoozeBit != 0;
      if (over(n.goalId) || (!snoozed && !wanted.contains(n.id))) await _gw.cancel(n.id);
    }
    // One already on screen (a sticky reminder, a ringing alarm) goes too.
    // Android drops its payload, so its id tells the goal.
    for (final n in await _gw.shown()) {
      final goalId = n.goalId ?? live.where((g) => reminderIdIsOf(n.id, g)).firstOrNull;
      if (goalId == null || over(goalId)) await _gw.cancel(n.id);
    }
    for (final r in plan) {
      await _gw.schedule(r);
    }
    state = RemindersState(permissions: state.permissions, planned: plan);
    return plan;
  }

  Future<void> setEnabled(String goalId, bool on) async {
    await ref.read(repositoryProvider).setSetting(reminderSettingKey(goalId), on ? 'true' : 'false');
    await sync();
  }

  /// Rings again after [minutes]; used by Snooze and by strict alarms that
  /// were left without progress.
  Future<void> ringAgain(Map<String, Object?> payload, int minutes, {bool countSnooze = true}) async {
    final goalId = payload['goalId'] as String;
    final view = ref.read(goalViewProvider(goalId));
    if (view == null) return;
    // Each snooze uses one of the snoozes left.
    final left = (((payload['maxSnoozes'] as num?) ?? 2).toInt() - (countSnooze ? 1 : 0)).clamp(0, 99);
    final (title, body) = reminderText(view);
    final step = LadderStep(
      minuteOfDay: 0,
      level: ReminderLevel.parse(payload['level']),
      maxSnoozes: left,
      snoozeMin: ((payload['snoozeMin'] as num?) ?? 10).toInt(),
      dismiss: (payload['dismiss'] as String?) ?? 'start_task',
      minMinutes: (payload['minMinutes'] as num?)?.toInt(),
      minPages: (payload['minPages'] as num?)?.toInt(),
    );
    final base = ((payload['id'] as num?) ?? 0).toInt();
    final r = PlannedReminder(
      id: (base & ~snoozeBit) | snoozeBit,
      goalId: goalId,
      day: ((payload['day'] as num?) ?? 0).toInt(),
      minuteOfDay: 0,
      step: step,
      title: title,
      body: body,
    );
    await _gw.schedule(
      r,
      at: ref.read(wallClockProvider)().add(Duration(minutes: minutes)),
      snoozed: step.maxSnoozes <= 0,
    );
  }

  Future<void> cancelRingAgain(Map<String, Object?> payload) async {
    final base = ((payload['id'] as num?) ?? 0).toInt();
    await _gw.cancel((base & ~snoozeBit) | snoozeBit);
  }

  Future<void> cancel(int id) => _gw.cancel(id);

  /// Pause all reminders for [days] days, today included. Spec §11.5.
  Future<void> pause(int days) async {
    final clock = ref.read(dayClockProvider);
    final today = clock.dayOfDateTime(ref.read(wallClockProvider)());
    await ref.read(repositoryProvider).setSetting('reminders.pausedUntil', DayClock.isoDate(today + days - 1));
    await sync();
  }

  Future<void> resume() async {
    await ref.read(repositoryProvider).setSetting('reminders.pausedUntil', '');
    await sync();
  }

  Future<void> setQuietHours(int start, int end) async {
    final repo = ref.read(repositoryProvider);
    await repo.setSetting('reminders.quietStart', clockText(start));
    await repo.setSetting('reminders.quietEnd', clockText(end));
    await sync();
  }
}

Map<String, Object?> decodePayload(String payload) => (jsonDecode(payload) as Map).cast<String, Object?>();
