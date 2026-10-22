import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'nudges.dart';
import 'usage_access_help.dart';
import 'wasted_time.dart';

/// Lost time today, this month and this year, from the phone. Read again when
/// usage access or the exclusions change, at a new day, and when the app
/// comes back (app.dart).
final timeLostProvider = FutureProvider<Map<LostPeriod, List<AppUsage>>>((ref) async {
  if (!ref.watch(nudgesProvider.select((s) => s.usageAccess))) return const {};
  final excluded = NudgeController.excludedApps(ref.watch(settingsProvider).value ?? const {});
  ref.watch(currentDayProvider);
  return ref.read(nudgeBridgeProvider).lostTime(excluded);
});

const _activity = {'social': 'scrolling', 'video': 'watching', 'game': 'playing', 'news': 'reading news'};

int _total(List<AppUsage> apps) => apps.fold<int>(0, (sum, u) => sum + u.minutes);

/// "Time lost": the first thing on the Today screen. Compact, it shows today;
/// a tap opens today, this month and this year, each with the top apps and
/// what that time could have been in the user's own goals. Without usage
/// access it is one row that leads to the setting.
class TimeLostCard extends ConsumerStatefulWidget {
  const TimeLostCard({super.key});

  @override
  ConsumerState<TimeLostCard> createState() => _TimeLostCardState();
}

class _TimeLostCardState extends ConsumerState<TimeLostCard> {
  bool _open = false;
  LostPeriod _period = LostPeriod.today;

  Future<void> _exclude(AppUsage app) async {
    final c = ref.read(nudgesProvider.notifier);
    final before = NudgeController.excludedApps(await ref.read(repositoryProvider).settings());
    await c.setExcluded([...before, app.package]);
    if (!mounted) return;
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
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    if (!ref.watch(nudgesProvider.select((s) => s.statusKnown))) return const SizedBox.shrink();
    if (!ref.watch(nudgesProvider.select((s) => s.usageAccess))) {
      return Card.outlined(
        key: const ValueKey('time-lost-setup'),
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.hourglass_empty),
          title: const Text('See how much time apps take from you'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showUsageAccessHelp(context, ref.read(nudgeBridgeProvider)),
        ),
      );
    }
    final lost = ref.watch(timeLostProvider).value ?? const {};
    if (lost.values.every((apps) => _total(apps) < 1)) return const SizedBox.shrink();
    final goals = ref.watch(goalsProvider).value ?? const [];
    final units = equivalentsFor([for (final g in goals) ?ref.watch(goalViewProvider(g.doc.id))]);
    final period = _open ? _period : LostPeriod.today;
    final apps = lost[period] ?? const [];
    final total = _total(apps);
    final could = couldHave(total, units);

    return Card.filled(
      key: const ValueKey('time-lost'),
      margin: EdgeInsets.zero,
      color: scheme.errorContainer.withValues(alpha: 0.55),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('time-lost-toggle'),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.hourglass_bottom, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Time lost · ${period.label.toLowerCase()}', style: t.titleMedium)),
                  Text(
                    formatDuration(total),
                    key: const ValueKey('time-lost-total'),
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onErrorContainer),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more, color: scheme.onErrorContainer),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Text(
                  ['On ${appKinds(apps)}.', if (could != null) 'That could have been $could.'].join(' '),
                  key: const ValueKey('time-lost-could'),
                  style: t.bodyMedium,
                  maxLines: _open ? null : 2,
                  overflow: _open ? null : TextOverflow.ellipsis,
                ),
              ),
              if (_open) ...[
                const SizedBox(height: 10),
                SegmentedButton<LostPeriod>(
                  key: const ValueKey('time-lost-periods'),
                  showSelectedIcon: false,
                  segments: [
                    for (final p in LostPeriod.values)
                      ButtonSegment(
                        value: p,
                        label: Text(p.label),
                        tooltip: formatDuration(_total(lost[p] ?? const [])),
                      ),
                  ],
                  selected: {_period},
                  onSelectionChanged: (v) => setState(() => _period = v.first),
                ),
                const SizedBox(height: 4),
                for (final u in apps.take(3))
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
                      onPressed: () => _exclude(u),
                    ),
                  ),
                if (period != LostPeriod.today)
                  Text(
                    'Counted by Android, including time before you installed Get On It.',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
