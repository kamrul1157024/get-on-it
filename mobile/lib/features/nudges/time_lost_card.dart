import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'nudges.dart';
import 'wasted_time.dart';

/// Today's lost time from the phone. Read again when usage access or the
/// exclusions change, at a new day, and when the app comes back (app.dart).
final timeLostProvider = FutureProvider<List<AppUsage>>((ref) async {
  if (!ref.watch(nudgesProvider.select((s) => s.usageAccess))) return const [];
  final excluded = NudgeController.excludedApps(ref.watch(settingsProvider).value ?? const {});
  ref.watch(currentDayProvider);
  return ref.read(nudgeBridgeProvider).usageToday(excluded);
});

const _activity = {'social': 'scrolling', 'video': 'watching', 'game': 'playing', 'news': 'reading news'};

/// "Time lost today": the total in distracting apps, the top three, and what
/// that time could have been in the user's own goals. Only with usage access.
class TimeLostCard extends ConsumerWidget {
  const TimeLostCard({super.key});

  Future<void> _exclude(BuildContext context, WidgetRef ref, AppUsage app) async {
    final c = ref.read(nudgesProvider.notifier);
    final before = NudgeController.excludedApps(await ref.read(repositoryProvider).settings());
    await c.setExcluded([...before, app.package]);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${app.label} no longer counts as lost time'),
          action: SnackBarAction(label: 'Undo', onPressed: () => c.setExcluded(before)),
        ),
      );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(timeLostProvider).value ?? const [];
    final total = usage.fold<int>(0, (sum, u) => sum + u.minutes);
    if (total < 1) return const SizedBox.shrink();
    final goals = ref.watch(goalsProvider).value ?? const [];
    final could = couldHave(total, equivalentsFor([for (final g in goals) ?ref.watch(goalViewProvider(g.doc.id))]));
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      key: const ValueKey('time-lost'),
      margin: EdgeInsets.zero,
      color: scheme.errorContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hourglass_bottom, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(child: Text('Time lost today', style: t.titleMedium)),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    formatDuration(total),
                    key: const ValueKey('time-lost-total'),
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            if (could != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text(
                  'That could have been $could.',
                  key: const ValueKey('time-lost-could'),
                  style: t.bodyMedium,
                ),
              ),
            const SizedBox(height: 4),
            for (final u in usage.take(3))
              ListTile(
                key: ValueKey('time-lost-app:${u.package}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(u.label),
                subtitle: Text([formatDuration(u.minutes), ?_activity[u.category]].join(' ')),
                trailing: IconButton(
                  key: ValueKey('time-lost-exclude:${u.package}'),
                  tooltip: 'Do not count ${u.label}',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _exclude(context, ref, u),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
