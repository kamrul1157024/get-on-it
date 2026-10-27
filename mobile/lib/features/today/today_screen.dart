import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/schema/validator.dart';
import '../../render/goal_surface.dart';
import '../goal/goal_screen.dart';
import '../import/ask_ai_screen.dart';
import '../import/direct_import.dart';
import '../import/import_screen.dart';
import '../nudges/time_lost_card.dart';
import '../settings/settings_screen.dart';

const sampleAssets = [
  'assets/samples/course-cs229.getonit.json',
  'assets/samples/book-atomic-habits.getonit.json',
  'assets/samples/habit-water.getonit.json',
  'assets/samples/habit-meditate.getonit.json',
];

/// All active goals, each drawn with its template's `tile_wide` surface.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});

  Future<void> _addSamples(WidgetRef ref) async {
    final repo = ref.read(repositoryProvider);
    final installed = await repo.templates();
    for (final asset in sampleAssets) {
      final parsed = parseImport(await rootBundle.loadString(asset), (r) => installed[r]);
      for (final g in parsed.goals) {
        await repo.saveGoal(g);
      }
    }
  }

  void _openImport(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    ref.watch(currentDayProvider);
    final t = Theme.of(context).textTheme;
    final list = goals.value ?? const [];
    final done = list.where((g) => ref.watch(goalViewProvider(g.doc.id))?.state['todayComplete'] == true).length;
    final highlighted = ref.watch(highlightedGoalsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Get On It'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      floatingActionButton: list.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('fab-import'),
              onPressed: () => _openImport(context),
              icon: const Icon(Icons.add),
              label: const Text('Import plan'),
            ),
      body: goals.isLoading && list.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
          ? _Empty(onImport: () => _openImport(context), onSamples: () => _addSamples(ref))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                Text(DateFormat('EEEE, d MMMM').format(DateTime.now()), style: t.titleLarge),
                Text('$done of ${list.length} done today', key: const ValueKey('today-summary'), style: t.bodyMedium),
                const SizedBox(height: 16),
                const TimeLostCard(),
                const SizedBox(height: 12),
                for (final g in list) ...[
                  _Highlight(
                    on: highlighted.contains(g.doc.id),
                    child: GoalSurface(
                      key: ValueKey('goal-tile:${g.doc.id}'),
                      goalId: g.doc.id,
                      surface: 'tile_wide',
                      fallback: Card(
                        child: ListTile(
                          title: Text(g.doc.title),
                          onTap: () =>
                              Navigator.of(context)
                                  .push(MaterialPageRoute(builder: (_) => GoalScreen(goalId: g.doc.id))),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

/// An outline around goals that were just added, so the user sees them.
class _Highlight extends StatelessWidget {
  const _Highlight({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 300),
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: on ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
    ),
    child: child,
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onImport, required this.onSamples});

  final VoidCallback onImport;
  final VoidCallback onSamples;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🎯', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            Text('No goals yet', style: t.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Ask any AI chat for a plan, then paste or share it here.',
              textAlign: TextAlign.center,
              style: t.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('empty-import'),
              onPressed: onImport,
              icon: const Icon(Icons.content_paste),
              label: const Text('Import a plan'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('empty-ask'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AskAiScreen())),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Make a plan with AI'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('empty-samples'),
              onPressed: onSamples,
              child: const Text('Add sample goals'),
            ),
          ],
        ),
      ),
    );
  }
}
