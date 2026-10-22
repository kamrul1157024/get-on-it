import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../reminders/gateway.dart';
import '../reminders/planner.dart';
import '../reminders/reminders_controller.dart';
import 'wasted_time.dart';

/// The native nudge service (android/.../nudge/NudgeService.kt). Tests use a
/// fake.
abstract class NudgeBridge {
  Future<void> configure(Map<String, Object?> config);

  Future<({bool running, bool usageAccess})> status();

  Future<void> openUsageAccessSettings();

  /// App info, where Android 13+ hides "Allow restricted settings".
  Future<void> openAppDetails();

  Future<List<({String package, String label})>> listApps();

  /// Lost time per app for today, this month and this year, most first,
  /// without [excluded]; empty without usage access.
  Future<Map<LostPeriod, List<AppUsage>>> lostTime(List<String> excluded);

  /// "Display over other apps", for the Push me hard stop screen.
  Future<bool> canDrawOverlays();

  Future<void> openOverlaySettings();
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
  Future<void> openAppDetails() => systemChannel.invokeMethod('openAppDetails');

  @override
  Future<List<({String package, String label})>> listApps() async {
    final list = await systemChannel.invokeListMethod<Map>('listApps') ?? const [];
    return [for (final m in list) (package: m['package'] as String, label: m['label'] as String)];
  }

  @override
  Future<Map<LostPeriod, List<AppUsage>>> lostTime(List<String> excluded) async {
    final m = await systemChannel.invokeMapMethod<String, Object?>('lostTime', excluded) ?? const {};
    return {
      for (final p in LostPeriod.values)
        p: [
          for (final a in (m[p.name] as List? ?? const []).whereType<Map>())
            AppUsage(
              a['package'] as String,
              a['label'] as String,
              a['category'] as String? ?? '',
              (a['minutes'] as num).toInt(),
            ),
        ],
    };
  }

  @override
  Future<bool> canDrawOverlays() async => await systemChannel.invokeMethod<bool>('canDrawOverlays') ?? false;

  @override
  Future<void> openOverlaySettings() => systemChannel.invokeMethod('openOverlaySettings');
}

final nudgeBridgeProvider = Provider<NudgeBridge>((ref) => const ChannelNudgeBridge());

/// "Display over other apps"; read again when the app comes back (app.dart).
final overlayAllowedProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.read(nudgeBridgeProvider).canDrawOverlays();
  } on MissingPluginException {
    return false;
  }
});

class WatchedApp {
  const WatchedApp(this.package, this.label, this.thresholdMin);

  final String package;
  final String label;
  final int thresholdMin;

  Map<String, Object?> toJson() => {'package': package, 'label': label, 'thresholdMin': thresholdMin};
}

/// How hard nudges push (android/.../nudge/NudgeRules.kt, Strength).
enum NudgeStrength {
  gentle('Gentle', '2 nudges a day, 3 h apart, a soft reminder.', 2, 180),
  firm('Firm', '4 a day, 2 h apart, with the time you lost.', 4, 120),
  hard('Push me hard', '12 a day, 20 min apart, and a stop screen over apps past their limit.', 12, 20);

  const NudgeStrength(this.label, this.help, this.maxPerDay, this.minGapMin);

  final String label;
  final String help;
  final int maxPerDay;
  final int minGapMin;

  static NudgeStrength parse(String? s) => values.where((v) => v.name == s).firstOrNull ?? firm;
}

class NudgeState {
  const NudgeState({
    this.enabled = false,
    this.strength = NudgeStrength.firm,
    this.unlock = true,
    this.apps = const [],
    this.running = false,
    this.usageAccess = false,
    this.pending = 0,
  });

  final bool enabled;
  final NudgeStrength strength;
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
      strength: NudgeStrength.parse(s['nudges.strength']),
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

  /// Units of today's open goals, to tell lost time in.
  Future<List<Equivalent>> equivalents() async => equivalentsFor([
    for (final g in await ref.read(repositoryProvider).allGoals()) ?ref.read(goalViewProvider(g.id)),
  ]);

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
      'strength': state.strength.name,
      'pending': pending,
      'equivalents': [for (final e in await equivalents()) e.toJson()],
      'excluded': excludedApps(settings),
    };
  }

  Future<void> push() async {
    final c = await config();
    try {
      await _bridge.configure(c);
      final st = await _bridge.status();
      state = NudgeState(
        enabled: state.enabled,
        strength: state.strength,
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
        strength: state.strength,
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

  Future<void> setStrength(NudgeStrength s) => ref.read(repositoryProvider).setSetting('nudges.strength', s.name);

  Future<void> setUnlock(bool on) => ref.read(repositoryProvider).setSetting('nudges.unlock', '$on');

  Future<void> setApps(List<WatchedApp> apps) =>
      ref.read(repositoryProvider).setSetting('nudges.apps', jsonEncode([for (final a in apps) a.toJson()]));

  /// Apps the user took off the lost-time list.
  static List<String> excludedApps(Map<String, String> settings) =>
      (jsonDecode(settings['nudges.excluded'] ?? '[]') as List).whereType<String>().toList();

  Future<void> setExcluded(List<String> packages) =>
      ref.read(repositoryProvider).setSetting('nudges.excluded', jsonEncode(packages));

  /// Apps suggested by the user's goals (`nudges.suggestedApps`); the user
  /// still chooses. Spec §12.2.
  Future<Set<String>> suggestedApps() async => {
    for (final g in await ref.read(repositoryProvider).allGoals())
      ...(((g.json['nudges'] as Map?)?['suggestedApps'] as List?) ?? const []).whereType<String>(),
  };
}
