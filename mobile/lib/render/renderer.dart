import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/binding/resolver.dart';
import 'components.dart';

typedef ActionHandler = Future<void> Function(Map<String, Object?> action);

/// Finds the tree and scope of another goal's surface, for `embed`.
typedef EmbedResolver = ({Map<String, Object?> tree, Map<String, Object?> scope})? Function(
  String goalId,
  String surface,
);

/// What a node needs to render: the binding scope and where actions go.
class RenderContext {
  const RenderContext({required this.scope, required this.onAction, this.embed});

  final Map<String, Object?> scope;
  final ActionHandler onAction;
  final EmbedResolver? embed;

  RenderContext withScope(Map<String, Object?> scope) => RenderContext(scope: scope, onAction: onAction, embed: embed);

  RenderContext withVar(String name, Object? value) => withScope({...scope, name: value});

  /// Resolves the action's bindings now, at tap time, and sends it.
  void dispatch(Object? action) {
    if (action is! Map) return;
    final resolved = resolve(action, scope);
    if (resolved is Map<String, Object?>) onAction(resolved);
  }
}

typedef ComponentBuilder = Widget Function(Map<String, Object?> node, RenderContext rc);

/// Renders one node. Unknown types use `fallback`, then a placeholder in debug
/// builds, then nothing. The renderer never throws for a document. Spec §6.6.
Widget buildNode(Object? raw, RenderContext rc) {
  if (raw is! Map) return const SizedBox.shrink();
  final node = raw.cast<String, Object?>();
  if (node.containsKey('visible') && !node.flag('visible', rc.scope)) {
    return const SizedBox.shrink();
  }
  final builder = componentBuilders[node['type']];
  if (builder == null) {
    if (node['fallback'] != null) return buildNode(node['fallback'], rc);
    if (kDebugMode) {
      return Text(
        'Unsupported component: ${node['type']}',
        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
      );
    }
    return const SizedBox.shrink();
  }
  try {
    final w = builder(node, rc);
    final id = node['id'];
    return id is String ? KeyedSubtree(key: ValueKey('node:$id'), child: w) : w;
  } catch (e) {
    if (kDebugMode) return Text('Render error in ${node['type']}: $e', style: const TextStyle(color: Colors.redAccent));
    return const SizedBox.shrink();
  }
}

List<Widget> buildChildren(Map<String, Object?> node, RenderContext rc) => [
  for (final c in (node['children'] as List? ?? const [])) buildNode(c, rc),
];
