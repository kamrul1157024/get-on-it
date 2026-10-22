import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../nudges/nudges.dart';
import '../nudges/usage_access_help.dart';
import '../reminders/reminders_controller.dart';

/// One permission the app can use. All of them are optional.
class AppPermission {
  const AppPermission({
    required this.id,
    required this.title,
    required this.why,
    required this.granted,
    required this.request,
  });

  /// Stored once the popup has shown it; never renamed.
  final String id;
  final String title;
  final String why;
  final Future<bool> Function() granted;

  /// Asks for it: a system dialog, or a settings page with help first.
  final Future<void> Function(BuildContext context) request;
}

final appPermissionsProvider = Provider<List<AppPermission>>((ref) {
  final gw = ref.read(reminderGatewayProvider);
  final nudges = ref.read(nudgeBridgeProvider);
  return [
    AppPermission(
      id: 'notifications',
      title: 'Notifications',
      why: 'Reminders for your goals.',
      granted: () async => (await gw.permissions()).notifications,
      request: (_) => gw.requestNotifications(),
    ),
    AppPermission(
      id: 'exactAlarms',
      title: 'Alarms on time',
      why: 'Reminders at the exact minute, not a few minutes late.',
      granted: () async => (await gw.permissions()).exactAlarms,
      request: (_) => gw.requestExactAlarms(),
    ),
    AppPermission(
      id: 'fullScreen',
      title: 'Full-screen alarms',
      why: 'Strict alarms that show over the lock screen.',
      granted: () async => (await gw.permissions()).fullScreen,
      request: (_) => gw.requestFullScreen(),
    ),
    AppPermission(
      id: 'usageAccess',
      title: 'Usage access',
      why: 'A nudge when you spend too long in other apps.',
      granted: () async => (await nudges.status()).usageAccess,
      request: (context) => showUsageAccessHelp(context, nudges),
    ),
  ];
});

/// Off in tests, which start with no permissions and would all see the popup.
final permissionPromptEnabledProvider = Provider<bool>((ref) => true);

const _shownKey = 'permissions.shown';

/// Asks once for the permissions that are missing. A permission the popup
/// has shown is never asked for again, allowed or not; a permission added in
/// a later version shows on its own.
Future<void> askForPermissionsOnce(BuildContext context, WidgetRef ref) async {
  if (!ref.read(permissionPromptEnabledProvider)) return;
  final repo = ref.read(repositoryProvider);
  final shown = ((await repo.settings())[_shownKey] ?? '').split(',').where((s) => s.isNotEmpty).toSet();
  final missing = <AppPermission>[];
  for (final p in ref.read(appPermissionsProvider)) {
    if (shown.contains(p.id)) continue;
    try {
      if (!await p.granted()) missing.add(p);
    } catch (_) {
      // A check that fails is not worth a popup.
    }
  }
  if (missing.isEmpty || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => PermissionPrompt(missing));
  await repo.setSetting(_shownKey, {...shown, ...missing.map((p) => p.id)}.join(','));
  await ref.read(remindersProvider.notifier).refreshPermissions();
  ref.read(nudgesProvider.notifier).refreshStatus();
}

class PermissionPrompt extends StatefulWidget {
  const PermissionPrompt(this.permissions, {super.key});

  final List<AppPermission> permissions;

  @override
  State<PermissionPrompt> createState() => _PermissionPromptState();
}

class _PermissionPromptState extends State<PermissionPrompt> with WidgetsBindingObserver {
  final _granted = <String, bool>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Most permissions are allowed on a system settings page; read them again
  // when the user comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final p in widget.permissions) {
      final ok = await p.granted().catchError((_) => false);
      if (!mounted) return;
      setState(() => _granted[p.id] = ok);
    }
  }

  Future<void> _allow(AppPermission p) async {
    await p.request(context);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      key: const ValueKey('permission-prompt'),
      title: const Text('Help Get On It help you'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Each one is optional. Skip any you do not want; the app will not ask again. '
                'You can change them later in Settings.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final p in widget.permissions)
                ListTile(
                  key: ValueKey('permission:${p.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.title),
                  subtitle: Text(p.why),
                  trailing: _granted[p.id] == true
                      ? Icon(Icons.check_circle, color: Colors.green, key: ValueKey('permission-ok:${p.id}'))
                      : TextButton(
                          key: ValueKey('permission-allow:${p.id}'),
                          onPressed: () => _allow(p),
                          child: const Text('Allow'),
                        ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('permission-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
