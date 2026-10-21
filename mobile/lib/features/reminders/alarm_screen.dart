import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../actions/action_router.dart';
import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../core/time/day_clock.dart';
import '../../render/components.dart';
import 'planner.dart';
import 'reminders_controller.dart';

/// Shown when an alarm rings. Spec §11.1 and §11.4.
///
/// A strict alarm cannot be closed until its challenge is met. If the user
/// leaves without progress, it rings again (3 min for do_task, 10 min for
/// start_task). The emergency exit is a 10-second hold, then "Skip today".
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.payload});

  final Map<String, Object?> payload;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> with SingleTickerProviderStateMixin {
  late final int _startMs;
  late final int _lastPageAtStart;
  late final AnimationController _hold;
  late final RemindersController _reminders;
  bool _opened = false;
  bool _closed = false;
  bool _metHandled = false;

  Map<String, Object?> get p => widget.payload;
  String get goalId => p['goalId'] as String;
  ReminderLevel get level => ReminderLevel.parse(p['level']);
  bool get strict => level == ReminderLevel.strictAlarm;
  String get dismiss => (p['dismiss'] as String?) ?? 'start_task';

  @override
  void initState() {
    super.initState();
    _reminders = ref.read(remindersProvider.notifier);
    _startMs = ref.read(wallClockProvider)().toUtc().millisecondsSinceEpoch;
    _lastPageAtStart = (ref.read(goalViewProvider(goalId))?.state['lastPage'] as int?) ?? 0;
    _hold = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _confirmSkip();
      });
    // Opening the alarm stops its sound.
    final id = ((p['id'] as num?) ?? 0).toInt();
    _reminders.cancel(id);
    _reminders.cancelRingAgain(p);
    if (strict) _reminders.ringAgain(p, dismiss == 'do_task' ? 3 : 10, countSnooze: false);
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  bool _met() {
    final view = ref.watch(goalViewProvider(goalId));
    final events = ref.watch(eventsProvider(goalId)).value ?? const <GoalEvent>[];
    return challengeMet(
      dismiss: dismiss,
      events: events,
      sinceUtcMs: _startMs,
      todayComplete: view?.state['todayComplete'] == true,
      minMinutes: (p['minMinutes'] as num?)?.toInt(),
      minPages: (p['minPages'] as num?)?.toInt(),
      lastPageAtStart: _lastPageAtStart,
      contentOpened: _opened,
    );
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  Future<void> _start() async {
    final view = ref.read(goalViewProvider(goalId));
    if (view == null) return;
    setState(() => _opened = true);
    await ActionRouter(context, ref).call(startWorkAction(view));
  }

  Future<void> _confirmSkip() async {
    _hold.reset();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Skip today?'),
        content: const Text('Today counts as a skipped day. Your streak stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep going')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Skip today')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final clock = ref.read(dayClockProvider);
    final today = clock.dayOfDateTime(ref.read(wallClockProvider)());
    await ref.read(repositoryProvider).addEvent(goalId, EventType.daySkipped, {
      'date': DayClock.isoDate(today),
      'reason': 'emergency_exit',
    });
    await _reminders.cancelRingAgain(p);
    setState(() => _metHandled = true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(goalViewProvider(goalId));
    final met = strict && _met();
    if (met && !_metHandled) {
      _metHandled = true;
      _reminders.cancelRingAgain(p);
    }
    final (title, body) = view == null ? ('', '') : reminderText(view);
    final t = Theme.of(context).textTheme;
    final canSnooze = !strict && ((p['maxSnoozes'] as num?) ?? 0) > 0;

    return PopScope(
      canPop: !strict || met,
      child: withAccent(
        context,
        view?.goal.accent,
        Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            return Scaffold(
              backgroundColor: scheme.primaryContainer,
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Spacer(),
                      Text(view?.goal.icon ?? '⏰', textAlign: TextAlign.center, style: const TextStyle(fontSize: 64)),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        key: const ValueKey('alarm-title'),
                        textAlign: TextAlign.center,
                        style: t.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(body, textAlign: TextAlign.center, style: t.titleMedium),
                      if (strict) ...[
                        const SizedBox(height: 16),
                        Text(
                          met
                              ? 'Done for now ✓'
                              : dismiss == 'do_task'
                              ? 'This alarm stops when you make progress.'
                              : 'This alarm stops when you start.',
                          key: const ValueKey('alarm-challenge'),
                          textAlign: TextAlign.center,
                          style: t.bodyMedium,
                        ),
                      ],
                      const Spacer(),
                      FilledButton(
                        key: const ValueKey('alarm-start'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                        onPressed: _start,
                        child: const Text('Get on it →', style: TextStyle(fontSize: 20)),
                      ),
                      const SizedBox(height: 12),
                      if (!strict) ...[
                        Row(
                          children: [
                            if (canSnooze)
                              Expanded(
                                child: OutlinedButton(
                                  key: const ValueKey('alarm-snooze'),
                                  onPressed: () async {
                                    await _reminders.ringAgain(p, ((p['snoozeMin'] as num?) ?? 10).toInt());
                                    _close();
                                  },
                                  child: Text('Snooze ${p['snoozeMin'] ?? 10} min'),
                                ),
                              ),
                            if (canSnooze) const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey('alarm-done'),
                                onPressed: () async {
                                  final v = ref.read(goalViewProvider(goalId));
                                  if (v != null) await completeToday(ref.read(repositoryProvider), v);
                                  _close();
                                },
                                child: const Text('Done today'),
                              ),
                            ),
                          ],
                        ),
                        TextButton(
                          key: const ValueKey('alarm-dismiss'),
                          onPressed: _close,
                          child: const Text('Dismiss'),
                        ),
                      ],
                      if (strict && met)
                        OutlinedButton(
                          key: const ValueKey('alarm-close'),
                          onPressed: _close,
                          child: const Text('Close'),
                        ),
                      if (strict && !met)
                        GestureDetector(
                          key: const ValueKey('alarm-emergency'),
                          onLongPressStart: (_) => _hold.forward(from: 0),
                          onLongPressEnd: (_) {
                            if (_hold.status != AnimationStatus.completed) _hold.reset();
                          },
                          child: AnimatedBuilder(
                            animation: _hold,
                            builder: (context, _) => Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: scheme.outline),
                                gradient: LinearGradient(
                                  colors: [scheme.errorContainer, Colors.transparent],
                                  stops: [_hold.value, _hold.value],
                                ),
                              ),
                              child: Text(
                                'Hold for 10 seconds to skip today',
                                textAlign: TextAlign.center,
                                style: t.bodyMedium,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
