import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../render/goal_surface.dart';

class GoalScreen extends ConsumerWidget {
  const GoalScreen({super.key, required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(goalViewProvider(goalId));
    return Scaffold(
      appBar: AppBar(
        title: Text(view?.goal.title ?? ''),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('goal-menu'),
            onSelected: (v) async {
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
            itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete goal'))],
          ),
        ],
      ),
      body: view == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [GoalSurface(goalId: goalId, surface: 'screen')],
            ),
    );
  }
}
