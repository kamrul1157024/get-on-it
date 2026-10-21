import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/schema/capabilities.dart';
import '../drive/drive_controller.dart';

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
