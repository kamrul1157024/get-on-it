import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/schema/capabilities.dart';
import '../../core/time/day_clock.dart';
import '../drive/drive_controller.dart';
import '../nudges/nudges.dart';
import '../reminders/planner.dart';
import '../reminders/reminders_controller.dart';

const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hour = ref.watch(dayClockProvider).dayStartHour;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('My day starts at'),
            subtitle: const Text('Work after midnight counts for the day before, until this hour.'),
            trailing: DropdownButton<int>(
              value: hour,
              items: [
                for (var h = 0; h <= 6; h++)
                  DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
              ],
              onChanged: (h) {
                if (h != null) ref.read(repositoryProvider).setSetting('dayStartHour', '$h');
              },
            ),
          ),
          const Divider(),
          const _RemindersSection(),
          const Divider(),
          const _NudgesSection(),
          const Divider(),
          const _DriveSection(),
          const Divider(),
          ListTile(
            title: const Text('Capability manifest'),
            subtitle: const Text('Give this to Claude so that it makes plans this app can show.'),
            trailing: const Icon(Icons.copy),
            onTap: () {
              final json = const JsonEncoder.withIndent('  ').convert(Capabilities.manifest(appVersion));
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
          const ListTile(title: Text('Version'), subtitle: Text(appVersion)),
        ],
      ),
    );
  }
}

/// Google Drive backup. Spec §13.
class _DriveSection extends ConsumerWidget {
  const _DriveSection();

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(driveProvider, (_, next) {
      final text = next.error ?? next.message;
      if (text != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    });
    final s = ref.watch(driveProvider);
    final c = ref.read(driveProvider.notifier);
    final last = s.lastBackupAt;
    final t = Theme.of(context).textTheme;
    return Padding(
      key: const ValueKey('drive-section'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Google Drive backup', style: t.titleMedium),
          const SizedBox(height: 4),
          Text(
            s.connected
                ? 'Connected as ${s.connection!.email}. The app saves a copy in the "Get On It" folder.'
                : 'Keep a copy of your goals and progress in your Google Drive. The app can only see its own files.',
            style: t.bodySmall,
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Last backup: ${MaterialLocalizations.of(context).formatShortDate(last)} '
                '${TimeOfDay.fromDateTime(last).format(context)}',
                key: const ValueKey('drive-last-backup'),
                style: t.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          if (s.busy) const LinearProgressIndicator(),
          Wrap(
            key: const ValueKey('drive-backup-buttons'),
            spacing: 8,
            runSpacing: 4,
            children: [
              if (!s.connected)
                FilledButton.icon(
                  key: const ValueKey('drive-connect'),
                  onPressed: s.busy ? null : c.connect,
                  icon: const Icon(Icons.add_to_drive),
                  label: const Text('Connect Google Drive'),
                ),
              if (s.connected) ...[
                FilledButton.tonal(
                  key: const ValueKey('drive-backup'),
                  onPressed: s.busy ? null : c.backupNow,
                  child: const Text('Back up now'),
                ),
                OutlinedButton(
                  key: const ValueKey('drive-restore'),
                  onPressed: s.busy
                      ? null
                      : () async {
                          if (await _confirm(
                            context,
                            'Restore from Drive?',
                            'Goals in the backup replace goals with the same name here. Progress is added, never removed.',
                            'Restore',
                          )) {
                            await c.restore();
                          }
                        },
                  child: const Text('Restore'),
                ),
                TextButton(
                  key: const ValueKey('drive-disconnect'),
                  onPressed: s.busy ? null : c.disconnect,
                  child: const Text('Disconnect'),
                ),
                TextButton(
                  key: const ValueKey('drive-delete'),
                  onPressed: s.busy
                      ? null
                      : () async {
                          if (await _confirm(
                            context,
                            'Delete the backup?',
                            'This deletes the "Get On It" folder from your Google Drive. Data on this phone stays.',
                            'Delete',
                          )) {
                            await c.deleteBackup();
                          }
                        },
                  child: const Text('Delete backup'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Reminder permissions and the rules a document cannot change. Spec §11.5.
class _RemindersSection extends ConsumerWidget {
  const _RemindersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(remindersProvider);
    final c = ref.read(remindersProvider.notifier);
    final gw = ref.read(reminderGatewayProvider);
    final settings = ref.watch(settingsProvider).value ?? const {};
    final rules = ReminderRules.fromSettings(settings);
    final today = ref.watch(currentDayProvider);
    final paused = rules.pausedUntilDay != null && rules.pausedUntilDay! >= today;
    final t = Theme.of(context).textTheme;

    Widget permission(String key, String label, String help, bool ok, Future<void> Function() request) => ListTile(
      key: ValueKey('perm-$key'),
      dense: true,
      leading: Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? Colors.green : Colors.orange),
      title: Text(label),
      subtitle: Text(help),
      trailing: ok
          ? null
          : TextButton(
              onPressed: () async {
                await request();
                await c.refreshPermissions();
              },
              child: const Text('Allow'),
            ),
    );

    Future<void> pickQuiet(bool start) async {
      final current = start ? rules.quietStart : rules.quietEnd;
      final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      );
      if (picked == null) return;
      final m = picked.hour * 60 + picked.minute;
      await c.setQuietHours(start ? m : rules.quietStart, start ? rules.quietEnd : m);
    }

    return Column(
      key: const ValueKey('reminders-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Reminders and alarms', style: t.titleMedium),
        ),
        permission(
          'notifications',
          'Notifications',
          'Needed for every reminder.',
          state.permissions.notifications,
          gw.requestNotifications,
        ),
        permission(
          'exact',
          'Alarms on time',
          'Without it, reminders can be a few minutes late.',
          state.permissions.exactAlarms,
          gw.requestExactAlarms,
        ),
        permission(
          'fullscreen',
          'Full-screen alarms',
          'Without it, alarms show as a ringing notification.',
          state.permissions.fullScreen,
          gw.requestFullScreen,
        ),
        ListTile(
          key: const ValueKey('quiet-hours'),
          title: const Text('Quiet hours'),
          subtitle: const Text('No reminders or alarms in this time.'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const ValueKey('quiet-start'),
                onPressed: () => pickQuiet(true),
                child: Text(clockText(rules.quietStart)),
              ),
              const Text('–'),
              TextButton(
                key: const ValueKey('quiet-end'),
                onPressed: () => pickQuiet(false),
                child: Text(clockText(rules.quietEnd)),
              ),
            ],
          ),
        ),
        ListTile(
          key: const ValueKey('pause'),
          title: Text(paused ? 'Paused until ${DayClock.isoDate(rules.pausedUntilDay!)}' : 'Pause all reminders'),
          subtitle: Text('At most ${rules.dailyAlarmLimit} alarms a day across all goals.'),
          trailing: paused
              ? TextButton(key: const ValueKey('pause-resume'), onPressed: c.resume, child: const Text('Resume'))
              : PopupMenuButton<int>(
                  key: const ValueKey('pause-menu'),
                  onSelected: c.pause,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('1 day')),
                    PopupMenuItem(value: 3, child: Text('3 days')),
                    PopupMenuItem(value: 7, child: Text('1 week')),
                  ],
                  child: const Padding(padding: EdgeInsets.all(8), child: Text('Pause')),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '${state.planned.length} reminders planned for the next 7 days',
            key: const ValueKey('planned-count'),
            style: t.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Distraction nudges. Spec §12.
class _NudgesSection extends ConsumerWidget {
  const _NudgesSection();

  Future<void> _chooseApps(BuildContext context, WidgetRef ref, NudgeState s) async {
    final c = ref.read(nudgesProvider.notifier);
    final apps = await ref.read(nudgeBridgeProvider).listApps();
    final suggested = await c.suggestedApps();
    if (!context.mounted) return;
    final chosen = {for (final a in s.apps) a.package: a};
    final result = await showDialog<Map<String, WatchedApp>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Apps to watch'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in [
                  ...apps.where((a) => suggested.contains(a.package)),
                  ...apps.where((a) => !suggested.contains(a.package)),
                ])
                  CheckboxListTile(
                    key: ValueKey('app:${a.package}'),
                    value: chosen.containsKey(a.package),
                    title: Text(a.label),
                    subtitle: suggested.contains(a.package) ? const Text('Suggested by your plan') : null,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        chosen[a.package] = WatchedApp(a.package, a.label, 15);
                      } else {
                        chosen.remove(a.package);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              key: const ValueKey('apps-save'),
              onPressed: () => Navigator.pop(context, chosen),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await c.setApps(result.values.toList());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(nudgesProvider);
    final c = ref.read(nudgesProvider.notifier);
    final t = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('nudges-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('nudges-enabled'),
          value: s.enabled,
          onChanged: c.setEnabled,
          title: Text('Distraction nudges', style: t.titleMedium),
          subtitle: Text(
            s.enabled
                ? (s.running ? 'On. ${s.pending} goals still open today.' : 'Starting…')
                : 'A short reminder of your goal when you unlock the phone or spend time in other apps.',
            key: const ValueKey('nudges-status'),
          ),
        ),
        if (s.enabled) ...[
          SwitchListTile(
            key: const ValueKey('nudges-unlock'),
            value: s.unlock,
            onChanged: c.setUnlock,
            title: const Text('When I unlock the phone'),
            subtitle: const Text('At most one nudge every 2 hours, and 4 a day.'),
          ),
          ListTile(
            key: const ValueKey('nudges-usage-access'),
            leading: Icon(
              s.usageAccess ? Icons.check_circle : Icons.error_outline,
              color: s.usageAccess ? Colors.green : Colors.orange,
            ),
            title: const Text('Usage access'),
            subtitle: const Text('Needed to see time in the apps you choose. Nothing leaves the phone.'),
            trailing: s.usageAccess
                ? null
                : TextButton(
                    onPressed: () => ref.read(nudgeBridgeProvider).openUsageAccessSettings(),
                    child: const Text('Allow'),
                  ),
          ),
          ListTile(
            key: const ValueKey('nudges-apps'),
            title: const Text('Apps to watch'),
            subtitle: Text(
              s.apps.isEmpty ? 'None' : s.apps.map((a) => '${a.label} (${a.thresholdMin} min)').join(', '),
              key: const ValueKey('nudges-apps-list'),
            ),
            trailing: TextButton(
              key: const ValueKey('nudges-choose'),
              onPressed: () => _chooseApps(context, ref, s),
              child: const Text('Choose'),
            ),
          ),
        ],
      ],
    );
  }
}
