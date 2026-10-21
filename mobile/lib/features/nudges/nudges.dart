import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../reminders/gateway.dart';
import '../reminders/planner.dart';
import '../reminders/reminders_controller.dart';

/// The native nudge service (android/.../nudge/NudgeService.kt). Tests use a
/// fake.
abstract class NudgeBridge {
  Future<void> configure(Map<String, Object?> config);

  Future<({bool running, bool usageAccess})> status();

  Future<void> openUsageAccessSettings();

  Future<List<({String package, String label})>> listApps();
}

class ChannelNudgeBridge implements NudgeBridge {
  const ChannelNudgeBridge();

  @override
  Future<void> configure(Map<String, Object?> config) =>
      systemChannel.invokeMethod('nudgeConfigure', jsonEncode(config));

  @override
  Future<({bool running, bool usageAccess})> status() async {
    final m = await systemChannel.invokeMapMethod<String, Object?>('nudgeStatus') ?? const {};
    return (running: m['running'] == true, usageAccess: m['usageAccess'] == true);
  }

  @override
  Future<void> openUsageAccessSettings() => systemChannel.invokeMethod('openUsageAccessSettings');

  @override
  Future<List<({String package, String label})>> listApps() async {
    final list = await systemChannel.invokeListMethod<Map>('listApps') ?? const [];
    return [for (final m in list) (package: m['package'] as String, label: m['label'] as String)];
  }
}

final nudgeBridgeProvider = Provider<NudgeBridge>((ref) => const ChannelNudgeBridge());

class WatchedApp {
  const WatchedApp(this.package, this.label, this.thresholdMin);

  final String package;
  final String label;
  final int thresholdMin;

  Map<String, Object?> toJson() => {'package': package, 'label': label, 'thresholdMin': thresholdMin};
}

class NudgeState {
  const NudgeState({
    this.enabled = false,
    this.unlock = true,
    this.apps = const [],
    this.running = false,
    this.usageAccess = false,
    this.pending = 0,
  });

  final bool enabled;
  final bool unlock;
  final List<WatchedApp> apps;
  final bool running;
  final bool usageAccess;

  /// Goals with work still open today; nudges point to the first.
  final int pending;
}

final nudgesProvider = NotifierProvider<NudgeController, NudgeState>(NudgeController.new);

/// Keeps the native service's copy of the settings and of today's open work
/// up to date. Spec §12.
class NudgeController extends Notifier<NudgeState> {
  Timer? _debounce;
  StreamSubscription<void>? _changes;

  NudgeBridge get _bridge => ref.read(nudgeBridgeProvider);

  @override
  NudgeState build() {
    // build() runs again on every settings change, and onDispose runs before
    // each rebuild, so the subscription is made fresh every time.
    ref.onDispose(() {
      _debounce?.cancel();
      _changes?.cancel();
      _changes = null;
    });
    _changes = ref.read(repositoryProvider).changes.listen((_) => _schedule());
    ref.listen(currentDayProvider, (_, _) => _schedule());
    final s = ref.watch(settingsProvider).value ?? const {};
    final apps = [
      for (final a in (jsonDecode(s['nudges.apps'] ?? '[]') as List).whereType<Map>())
        WatchedApp(a['package'] as String, a['label'] as String, (a['thresholdMin'] as num?)?.toInt() ?? 15),
    ];
    _schedule();
    return NudgeState(
      enabled: s['nudges.enabled'] == 'true',
      unlock: s['nudges.unlock'] != 'false',
      apps: apps,
      running: stateOrNull?.running ?? false,
      usageAccess: stateOrNull?.usageAccess ?? false,
      pending: stateOrNull?.pending ?? 0,
    );
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), push);
  }

  /// Today's open work, in Today-screen order: what a nudge points to.
  Future<List<Map<String, Object?>>> pendingWork() async {
    final repo = ref.read(repositoryProvider);
    final out = <Map<String, Object?>>[];
    for (final g in await repo.allGoals()) {
      final view = ref.read(goalViewProvider(g.id));
      if (view == null) continue;
      final s = view.state;
      if (s['todayComplete'] == true || s['todayScheduled'] == false || s['isComplete'] == true) continue;
      final (title, body) = reminderText(view);
      out.add({'goalId': g.id, 'title': title, 'body': body, 'link': 'getonit://start/${g.id}'});
    }
    return out;
  }

  Future<Map<String, Object?>> config() async {
    final settings = await ref.read(repositoryProvider).settings();
    final rules = ReminderRules.fromSettings(settings);
    final pending = await pendingWork();
    return {
      'enabled': state.enabled,
      'unlock': state.unlock,
      'apps': [for (final a in state.apps) a.toJson()],
      'quietStartMin': rules.quietStart,
      'quietEndMin': rules.quietEnd,
      'maxPerDay': 4,
      'minGapMin': 120,
      'pending': pending,
    };
  }

  Future<void> push() async {
    final c = await config();
    try {
      await _bridge.configure(c);
      final st = await _bridge.status();
      state = NudgeState(
        enabled: state.enabled,
        unlock: state.unlock,
        apps: state.apps,
        running: st.running,
        usageAccess: st.usageAccess,
        pending: (c['pending'] as List).length,
      );
    } on MissingPluginException {
      // No native side (for example in some tests).
    }
  }

  Future<void> refreshStatus() async {
    try {
      final st = await _bridge.status();
      state = NudgeState(
        enabled: state.enabled,
        unlock: state.unlock,
        apps: state.apps,
        running: st.running,
        usageAccess: st.usageAccess,
        pending: state.pending,
      );
    } on MissingPluginException {
      return;
    }
  }

  Future<void> setEnabled(bool on) => ref.read(repositoryProvider).setSetting('nudges.enabled', '$on');

  Future<void> setUnlock(bool on) => ref.read(repositoryProvider).setSetting('nudges.unlock', '$on');

  Future<void> setApps(List<WatchedApp> apps) =>
      ref.read(repositoryProvider).setSetting('nudges.apps', jsonEncode([for (final a in apps) a.toJson()]));

  /// Apps suggested by the user's goals (`nudges.suggestedApps`); the user
  /// still chooses. Spec §12.2.
  Future<Set<String>> suggestedApps() async => {
    for (final g in await ref.read(repositoryProvider).allGoals())
      ...(((g.json['nudges'] as Map?)?['suggestedApps'] as List?) ?? const []).whereType<String>(),
  };
}
