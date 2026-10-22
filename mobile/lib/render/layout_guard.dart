import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps a layout failure inside [child].
///
/// Flutter reports a failed layout and leaves that box without a size; every
/// parent that then reads the size fails too, up to the screen. One bad part
/// of a template blanked the whole goal screen, and in the import preview it
/// left the "Fix with AI" button below without a size, so it could not be
/// tapped. This box lays the child out, and when any box under it has no size
/// it skips the child and draws a short note in its place.
class LayoutGuard extends SingleChildRenderObjectWidget {
  const LayoutGuard({super.key, required super.child});

  @override
  RenderLayoutGuard createRenderObject(BuildContext context) =>
      RenderLayoutGuard(color: Theme.of(context).colorScheme.error);

  @override
  void updateRenderObject(BuildContext context, RenderLayoutGuard renderObject) {
    renderObject.color = Theme.of(context).colorScheme.error;
  }
}

class RenderLayoutGuard extends RenderProxyBox {
  RenderLayoutGuard({required Color color}) : _color = color; // ignore: prefer_initializing_formals

  static const note = 'This part could not be drawn.';

  Color _color;
  set color(Color c) {
    if (c == _color) return;
    _color = c;
    markNeedsPaint();
  }

  bool failed = false;
  TextPainter? _painter;

  @override
  void performLayout() {
    final c = child;
    failed = false;
    if (c != null) {
      try {
        c.layout(constraints, parentUsesSize: true);
        // A failure deep inside moves up: each parent that reads the size of a
        // child without one fails as well, up to this child. The subtree is
        // not walked here: parts that lay out on their own come later in the
        // same frame and have no size yet.
        failed = !c.hasSize || !c.size.isFinite;
      } catch (_) {
        failed = true;
      }
    }
    if (c != null && !failed) {
      size = constraints.constrain(c.size);
      return;
    }
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 240.0;
    _painter = TextPainter(
      text: TextSpan(
        text: note,
        style: TextStyle(color: _color, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    size = constraints.constrain(Size(width, _painter!.height + 8));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!failed) return super.paint(context, offset);
    _painter?.paint(context.canvas, offset + const Offset(0, 4));
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!failed) super.visitChildrenForSemantics(visitor);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      !failed && super.hitTestChildren(result, position: position);

  // A parent that asks for intrinsic sizes (a grid row of equal height) gets
  // zero instead of an error from a child that cannot answer.
  double _safe(double Function() f) {
    try {
      final v = f();
      return v.isFinite ? v : 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => _safe(() => super.computeMinIntrinsicWidth(height));

  @override
  double computeMaxIntrinsicWidth(double height) => _safe(() => super.computeMaxIntrinsicWidth(height));

  @override
  double computeMinIntrinsicHeight(double width) => _safe(() => super.computeMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => _safe(() => super.computeMaxIntrinsicHeight(width));
}

/// Whether everything under [root] laid out, after the frame: every box has
/// a finite size and no guard had to catch a failure.
bool laidOut(RenderObject root) {
  var ok = true;
  void visit(RenderObject o) {
    if (!ok) return;
    if ((o is RenderBox && (!o.hasSize || !o.size.isFinite)) || (o is RenderLayoutGuard && o.failed)) {
      ok = false;
      return;
    }
    o.visitChildren(visit);
  }

  visit(root);
  return ok;
}
