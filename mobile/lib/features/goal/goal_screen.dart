import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../render/goal_surface.dart';
import '../import/ask_ai_screen.dart';
import '../../core/time/clock_format.dart';
import '../reminders/planner.dart';
import '../reminders/reminder_labels.dart';
import '../reminders/reminders_controller.dart';

class GoalScreen extends ConsumerWidget {
  const GoalScreen({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(goalViewProvider(goalId));
    final remindersOn = ref.watch(settingsProvider).value?[reminderSettingKey(goalId)] == 'true';
    return Scaffold(
      appBar: AppBar(
        title: Text(view?.goal.title ?? ''),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('goal-menu'),
            onSelected: (v) async {
              if (v == 'reminders-on' || v == 'reminders-off') {
                await ref.read(remindersProvider.notifier).setEnabled(goalId, v == 'reminders-on');
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(v == 'reminders-on' ? 'Reminders on' : 'Reminders off')));
                }
                return;
              }
              if (v == 'edit-ai' || v == 'look-ai') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AskAiScreen(goalId: goalId, look: v == 'look-ai'),
                  ),
                );
                return;
              }
              if (v != 'delete') return;
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Delete this goal?'),
                  content: const Text('The goal and all its progress will be deleted.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(repositoryProvider).deleteGoal(goalId);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [
              if (view?.goal.reminders != null)
                remindersOn
                    ? const PopupMenuItem(value: 'reminders-off', child: Text('Turn reminders off'))
                    : PopupMenuItem(
                        value: 'reminders-on',
                        child: Text(turnOnLabel(view!.goal, use24h: MediaQuery.alwaysUse24HourFormatOf(context))),
                      ),
              const PopupMenuItem(value: 'edit-ai', child: Text('Change plan with AI')),
              const PopupMenuItem(value: 'look-ai', child: Text('Change the look with AI')),
              const PopupMenuItem(value: 'delete', child: Text('Delete goal')),
            ],
          ),
        ],
      ),
      body: view == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _ReminderAsk(goalId: goalId),
                GoalSurface(goalId: goalId, surface: 'screen'),
              ],
            ),
    );
  }
}

/// "Turn on reminders at 7:00 PM?" once, for a plan that proposes reminders
/// and has them off. The import screen used to ask this.
class _ReminderAsk extends ConsumerWidget {
  const _ReminderAsk({required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(goalViewProvider(goalId));
    final settings = ref.watch(settingsProvider).value;
    final steps = view == null ? const [] : ladderOf(view.goal);
    if (settings == null ||
        steps.isEmpty ||
        settings[reminderSettingKey(goalId)] == 'true' ||
        settings['reminders.asked.$goalId'] == 'true') {
      return const SizedBox.shrink();
    }
    Future<void> answer(bool on) async {
      await ref.read(repositoryProvider).setSetting('reminders.asked.$goalId', 'true');
      if (on) await ref.read(remindersProvider.notifier).setEnabled(goalId, true);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card.filled(
        key: const ValueKey('reminder-ask'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Turn on reminders at ${clockOf(context, steps.first.minuteOfDay)}?',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                ladderDescription(view!.goal, use24h: MediaQuery.alwaysUse24HourFormatOf(context)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('reminder-ask-no'),
                    onPressed: () => answer(false),
                    child: const Text('No'),
                  ),
                  FilledButton.tonal(
                    key: const ValueKey('reminder-ask-yes'),
                    onPressed: () => answer(true),
                    child: const Text('Yes'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
