import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../actions/action_router.dart';
import 'update_service.dart';

/// Says once what a new release changed. Closing the dialog by any route
/// counts as read; Settings still offers the update afterwards.
Future<void> checkForUpdateOnStart(BuildContext context, WidgetRef ref) async {
  final service = ref.read(updateServiceProvider);
  if (!service.isReleaseBuild) return;
  final info = await service.check();
  if (info == null || await service.isDismissed(info.latestVersion) || !context.mounted) return;
  await showUpdateDialog(context, ref, info);
  await service.dismiss(info.latestVersion);
}

/// The "Check for updates" row in Settings: always answers.
Future<void> checkForUpdateNow(BuildContext context, WidgetRef ref) async {
  final service = ref.read(updateServiceProvider);
  final info = await service.check();
  if (!context.mounted) return;
  if (info == null) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('You have the latest version (${service.currentVersion}), or GitHub did not answer.')),
      );
    return;
  }
  await showUpdateDialog(context, ref, info);
}

Future<void> showUpdateDialog(BuildContext context, WidgetRef ref, UpdateInfo info) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    key: const ValueKey('update-dialog'),
    title: Text('Get On It ${info.latestVersion} is out'),
    content: SizedBox(
      width: double.maxFinite,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your goals and progress stay. The update installs over this app.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final note in info.notes) _ReleaseSection(note),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(key: const ValueKey('update-later'), onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
      FilledButton(
        key: const ValueKey('update-install'),
        onPressed: () {
          Navigator.pop(ctx);
          final url = info.apkUrl;
          if (url == null) {
            ref.read(externalLauncherProvider)(Uri.parse(releasesPageUrl));
          } else {
            _install(context, ref, url);
          }
        },
        child: Text(info.apkUrl == null ? 'Open download page' : 'Install'),
      ),
    ],
  ),
);

Future<void> _install(BuildContext context, WidgetRef ref, String url) async {
  final progress = ValueNotifier<double?>(null);
  final messenger = ScaffoldMessenger.of(context);
  final banner = messenger.showSnackBar(
    SnackBar(
      duration: const Duration(minutes: 10),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, p, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p == null ? 'Downloading the update…' : 'Downloading the update… ${(p * 100).round()}%'),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: p),
          ],
        ),
      ),
    ),
  );
  try {
    await ref.read(apkInstallerProvider).install(url, onProgress: (p) => progress.value = p);
    banner.close();
  } catch (e) {
    banner.close();
    messenger.showSnackBar(SnackBar(content: Text('The update failed: $e')));
  }
}

class _ReleaseSection extends StatelessWidget {
  const _ReleaseSection(this.note);

  final ReleaseNote note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final date = note.publishedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            date == null ? note.version : '${note.version} · ${DateFormat('d MMM y').format(date.toLocal())}',
            style: t.titleSmall,
          ),
          const SizedBox(height: 4),
          if (note.body.isEmpty)
            Text('No notes for this release.', style: t.bodySmall)
          else
            MarkdownBody(
              data: note.body,
              // GitHub's notes start with "## What's Changed"; a dialog needs
              // small headings.
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(h1: t.titleSmall, h2: t.titleSmall, h3: t.titleSmall, p: t.bodySmall),
            ),
        ],
      ),
    );
  }
}
