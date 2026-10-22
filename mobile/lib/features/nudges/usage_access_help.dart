import 'package:flutter/material.dart';

import 'nudges.dart';

/// Guides the user to usage access. Android 13+ blocks it for an app
/// installed from a downloaded APK ("App was denied access", "Controlled by
/// Restricted Setting") until the user allows restricted settings on the App
/// info page. The app cannot do that step itself, and cannot tell whether
/// the phone blocks it, so the steps show every time.
Future<void> showUsageAccessHelp(BuildContext context, NudgeBridge bridge) => showDialog<void>(
  context: context,
  builder: (ctx) {
    final t = Theme.of(ctx).textTheme;
    Widget step(String n, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 22, child: Text(n, style: t.titleSmall)),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return AlertDialog(
      key: const ValueKey('usage-help'),
      title: const Text('Allow usage access'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            step('1', 'Open usage access and turn on the switch for Get On It.'),
            Text('If Android says "App was denied access" or "Controlled by Restricted Setting":', style: t.bodySmall),
            const SizedBox(height: 8),
            step('2', 'Open App info, tap ⋮ at the top right, then "Allow restricted settings".'),
            step('3', 'Open usage access again and turn on the switch.'),
            Text(
              'Android asks this of apps that are not from the Play Store. Get On It only reads which app is open, '
              'to nudge you, and keeps it on the phone.',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
      // The dialog stays open while the user goes back and forth between
      // the two settings pages; it closes on "Close".
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(key: const ValueKey('usage-close'), onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        TextButton(
          key: const ValueKey('usage-open-app-info'),
          onPressed: bridge.openAppDetails,
          child: const Text('Open App info'),
        ),
        FilledButton(
          key: const ValueKey('usage-open-settings'),
          onPressed: bridge.openUsageAccessSettings,
          child: const Text('Open usage access'),
        ),
      ],
    );
  },
);

/// Guides the user to "Display over other apps" for the Push me hard stop
/// screen. Android 13+ can restrict it for an app from a downloaded APK, the
/// same way as usage access.
Future<void> showOverlayHelp(BuildContext context, NudgeBridge bridge) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    key: const ValueKey('overlay-help'),
    title: const Text('Allow the stop screen'),
    content: const Text(
      'Open "Display over other apps" and turn on the switch for Get On It. '
      'If Android says the setting is restricted: open App info, tap ⋮, then "Allow restricted settings", '
      'and try again.\n\nGet On It uses it only to show the stop screen over an app past its limit.',
    ),
    actions: [
      TextButton(key: const ValueKey('overlay-close'), onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      TextButton(onPressed: bridge.openAppDetails, child: const Text('Open App info')),
      FilledButton(
        key: const ValueKey('overlay-open-settings'),
        onPressed: bridge.openOverlaySettings,
        child: const Text('Open setting'),
      ),
    ],
  ),
);
