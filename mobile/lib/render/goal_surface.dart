import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../actions/action_router.dart';
import '../app/providers.dart';
import 'components.dart';
import 'layout_guard.dart';
import 'renderer.dart';

/// Renders one surface of one goal, with actions routed to the app.
class GoalSurface extends ConsumerWidget {
  const GoalSurface({super.key, required this.goalId, required this.surface, this.fallback});

  final String goalId;
  final String surface;
  final Widget? fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(goalViewProvider(goalId));
    if (view == null) return const SizedBox.shrink();
    final tree = view.template?.surface(surface);
    if (tree == null) {
      return fallback ??
          Card(
            child: ListTile(title: Text(view.goal.title), subtitle: const Text('This template has no view here.')),
          );
    }
    final rc = RenderContext(
      scope: view.scope,
      onAction: ActionRouter(context, ref).call,
      embed: (id, name) {
        final other = ref.read(goalViewProvider(id));
        final t = other?.template?.surface(name);
        return other == null || t == null ? null : (tree: t, scope: other.scope);
      },
    );
    return withAccent(context, view.goal.accent, LayoutGuard(child: Builder(builder: (_) => buildNode(tree, rc))));
  }
}
