// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Viewport-overflow detection for agent-generated widget trees
/// (issue #692 C).
///
/// Generated UI is dimension-blind no more: the app-state context now
/// carries the viewport (see `app_state_context.dart`), and this watcher is
/// the runtime backstop — it walks the laid-out subtree after each frame
/// and reports when content paints WIDER than the allotted viewport (the
/// "Карточка продуктивности" row clipped at the right edge). The host
/// turns the report into an agent-visible note plus a tile warning.
///
/// Detection rules:
/// - width-only (vertical overflow inside the canvas's scroll view is by
///   design — content taller than the canvas scrolls);
/// - nodes inside a NESTED scrollable viewport are skipped (a horizontal
///   carousel scrolling its own content is intentional, not overflow);
/// - a 4 px tolerance keeps sub-pixel rounding noise out;
/// - the walk is node-capped and runs post-frame, never during layout.

library;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Reports a horizontal overflow: [overflowPx] is how far past the right
/// edge the widest node paints, [viewportWidth] the allotted width.
typedef WidgetOverflowCallback =
    void Function(double overflowPx, double viewportWidth);

/// Watches [child]'s laid-out subtree for horizontal overflow.
class WidgetOverflowWatch extends SingleChildRenderObjectWidget {
  const WidgetOverflowWatch({
    super.key,
    required this.onOverflow,
    required super.child,
  });

  final WidgetOverflowCallback onOverflow;

  @override
  RenderWidgetOverflowWatch createRenderObject(BuildContext context) =>
      RenderWidgetOverflowWatch(onOverflow: onOverflow);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderWidgetOverflowWatch renderObject,
  ) {
    renderObject.onOverflow = onOverflow;
  }
}

/// The render side of [WidgetOverflowWatch]: schedules a post-frame walk
/// after every layout pass.
class RenderWidgetOverflowWatch extends RenderProxyBox {
  RenderWidgetOverflowWatch({required this._onOverflow});

  WidgetOverflowCallback _onOverflow;

  set onOverflow(WidgetOverflowCallback value) => _onOverflow = value;

  /// Sub-pixel/rounding noise below this is not an overflow.
  static const double tolerancePx = 4;

  /// Hard cap on visited render nodes per walk (deep trees degrade to a
  /// prefix instead of ever stalling the frame pipeline).
  static const int maxNodeVisits = 2000;

  bool _checkScheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (child != null && !_checkScheduled) {
      _checkScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  void _check() {
    _checkScheduled = false;
    final subtree = child;
    if (!attached || subtree == null) return;
    final viewportWidth = size.width;
    var maxRight = 0.0;
    var visits = 0;

    void visit(RenderObject node) {
      if (visits++ > maxNodeVisits) return;
      if (node is RenderBox && !_insideNestedViewport(node)) {
        final size = node.size;
        final origin = node.localToGlobal(Offset.zero, ancestor: this).dx;
        final right = node
            .localToGlobal(Offset(size.width, 0), ancestor: this)
            .dx;
        final rightBottom = node
            .localToGlobal(Offset(size.width, size.height), ancestor: this)
            .dx;
        final edge = origin > right
            ? origin
            : (right > rightBottom ? right : rightBottom);
        if (edge > maxRight) maxRight = edge;
      }
      node.visitChildren(visit);
    }

    visit(subtree);
    if (maxRight > viewportWidth + tolerancePx) {
      _onOverflow(maxRight - viewportWidth, viewportWidth);
    }
  }

  /// Whether a nested scrollable sits between [node] and this watcher —
  /// its own viewport owns horizontal clipping/scrolling, so its content
  /// is not an overflow of THIS viewport.
  bool _insideNestedViewport(RenderObject node) {
    for (
      RenderObject? ancestor = node.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      if (identical(ancestor, this)) return false;
      if (ancestor is RenderAbstractViewport) return true;
    }
    return false;
  }
}
