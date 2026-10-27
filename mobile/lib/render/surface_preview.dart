import 'package:flutter/material.dart';

import 'layout_guard.dart';
import 'renderer.dart';

/// Draws one surface for the import preview and reports whether it laid out.
///
/// A layout failure inside a template does not throw to the caller: Flutter
/// reports it and leaves the broken part without a size, and in the app that
/// showed as a blank goal screen. After each frame this walks the drawn tree
/// and calls [onLayout] with false when any part has no size or an endless one.
class SurfacePreview extends StatefulWidget {
  const SurfacePreview({super.key, required this.tree, required this.scope, required this.onLayout, this.onAction});

  final Map<String, Object?> tree;
  final Map<String, Object?> scope;
  final ValueChanged<bool> onLayout;
  final ActionHandler? onAction;

  @override
  State<SurfacePreview> createState() => _SurfacePreviewState();
}

class _SurfacePreviewState extends State<SurfacePreview> {
  final _key = GlobalKey();
  bool? _reported;

  void _probe(Duration _) {
    if (!mounted) return;
    final root = _key.currentContext?.findRenderObject();
    if (root == null) return;
    final ok = laidOut(root);
    if (ok != _reported) {
      _reported = ok;
      widget.onLayout(ok);
    }
  }

  // A new check of the plan brings a new scope: report the layout again,
  // even when the result is the same as before.
  @override
  void didUpdateWidget(SurfacePreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.scope, widget.scope) || !identical(old.tree, widget.tree)) _reported = null;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_probe);
    final rc = RenderContext(scope: widget.scope, onAction: widget.onAction ?? (_) async {});
    return LayoutGuard(key: _key, child: buildNode(widget.tree, rc));
  }
}
