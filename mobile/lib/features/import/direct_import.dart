import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/events/goal_event.dart';
import '../../core/schema/documents.dart';
import '../../core/schema/validator.dart';
import '../../render/components.dart';
import '../../render/surface_preview.dart';
import '../../render/template_lint.dart';
import '../goal/goal_screen.dart';
import '../reminders/reminders_controller.dart';
import 'import_screen.dart';
import 'plan_finder.dart';

/// Goals added by the last direct import, outlined on Today for a moment.
final highlightedGoalsProvider = NotifierProvider<HighlightedGoals, Set<String>>(HighlightedGoals.new);

class HighlightedGoals extends Notifier<Set<String>> {
  Timer? _clear;

  @override
  Set<String> build() {
    ref.onDispose(() => _clear?.cancel());
    return const {};
  }

  void show(Set<String> ids) {
    _clear?.cancel();
    state = ids;
    _clear = Timer(const Duration(seconds: 6), () => state = const {});
  }
}

/// A plan from the AI chat, saved without the import screen when nothing is
/// wrong with it: no errors, no warnings, and every screen and widget lays
/// out. Then the plan page opens (Today for several goals) with "Undo". A plan
/// with any problem opens the import screen, with the problems and Fix with AI.
Future<void> importOrReview(BuildContext context, WidgetRef ref, String text) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  // The screen that asked may close before Undo is tapped; the container
  // lives as long as the app.
  final container = ProviderScope.containerOf(context, listen: false);
  void review() => navigator.push(MaterialPageRoute(builder: (_) => ImportScreen(initialText: text)));

  await container.read(bootstrapProvider.future);
  final repo = container.read(repositoryProvider);
  final installed = await repo.templates();
  final parsed = parseImport(text, (r) => installed[r]);
  if (!parsed.ok || parsed.issues.isNotEmpty || parsed.goals.isEmpty) return review();

  final clock = container.read(dayClockProvider);
  final now = container.read(wallClockProvider)();
  final probes = <_Probe>[];
  for (final g in parsed.goals) {
    final template = parsed.templates.where((t) => t.ref == g.templateRef).firstOrNull ?? installed[g.templateRef];
    if (template == null) return review();
    final existing = await repo.goal(g.id);
    final events = existing == null
        ? const <GoalEvent>[]
        : (await repo.allEvents()).where((e) => e.goalId == g.id).toList();
    final state = previewState(template, g, clock: clock, now: now, events: events, createdAt: existing?.createdAt);
    if (lintTemplate(template, g, state).isNotEmpty) return review();
    final scope = {'goal': g.scopeValue, 'data': g.data, 'state': state};
    for (final s in ['screen', 'tile', 'tile_wide']) {
      final tree = template.surface(s);
      if (tree != null) probes.add(_Probe(tree, scope, g.accent, s == 'tile'));
    }
  }
  if (!context.mounted) return;
  if (!await _laysOut(context, probes)) return review();

  // What Undo puts back.
  final before = <String, GoalDoc?>{for (final g in parsed.goals) g.id: (await repo.goal(g.id))?.doc};
  final templatesBefore = <String, TemplateDoc?>{for (final t in parsed.templates) t.ref: installed[t.ref]};

  for (final t in parsed.templates) {
    await repo.installTemplate(t);
  }
  for (final g in parsed.goals) {
    await repo.saveGoal(g);
  }
  container.read(remindersProvider.notifier).scheduleSync();
  await markPlanSeenIn(repo, text.trim());

  final ids = [for (final g in parsed.goals) g.id];
  final updated = before.values.any((d) => d != null);
  navigator.popUntil((r) => r.isFirst);
  if (ids.length == 1) {
    unawaited(navigator.push(MaterialPageRoute(builder: (_) => GoalScreen(goalId: ids.single))));
  } else {
    container.read(highlightedGoalsProvider.notifier).show(ids.toSet());
  }

  Future<void> undo() async {
    for (final e in before.entries) {
      final old = e.value;
      if (old == null) {
        await repo.deleteGoal(e.key);
      } else {
        await repo.saveGoal(old);
      }
    }
    final remaining = await repo.activeGoals();
    for (final e in templatesBefore.entries) {
      final old = e.value;
      if (old != null) {
        await repo.restoreTemplate(old);
      } else if (!remaining.any((g) => g.doc.templateRef == e.key)) {
        final t = parsed.templates.firstWhere((t) => t.ref == e.key);
        await repo.deleteTemplate(t.id, t.major);
      }
    }
    container.read(remindersProvider.notifier).scheduleSync();
    if (ids.length == 1 && !updated) navigator.popUntil((r) => r.isFirst);
  }

  final n = ids.length;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const ValueKey('import-done'),
        duration: const Duration(seconds: 8),
        content: Text(n > 1 ? '$n goals added.' : (updated ? 'Plan updated.' : 'Plan added.')),
        action: SnackBarAction(key: const ValueKey('import-undo'), label: 'Undo', onPressed: undo),
      ),
    );
}

class _Probe {
  const _Probe(this.tree, this.scope, this.accent, this.small);

  final Map<String, Object?> tree;
  final Map<String, Object?> scope;
  final String? accent;
  final bool small;
}

/// Lays every surface out offstage, at the width it gets on the phone, and
/// reports whether all of them laid out. The same check as the preview.
Future<bool> _laysOut(BuildContext context, List<_Probe> probes) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null || probes.isEmpty) return true;
  final results = <int, bool>{};
  final width = MediaQuery.sizeOf(context).width - 32;
  final entry = OverlayEntry(
    builder: (ctx) => Offstage(
      child: SingleChildScrollView(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < probes.length; i++)
                SizedBox(
                  width: probes[i].small ? 170 : width,
                  child: withAccent(
                    ctx,
                    probes[i].accent,
                    SurfacePreview(tree: probes[i].tree, scope: probes[i].scope, onLayout: (ok) => results[i] = ok),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    for (var frame = 0; frame < 10 && results.length < probes.length; frame++) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
  } finally {
    entry.remove();
  }
  return results.values.every((ok) => ok);
}
