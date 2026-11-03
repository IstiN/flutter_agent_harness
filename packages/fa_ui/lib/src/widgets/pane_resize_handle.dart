// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';

/// The shared pane-divider resize handle (owner unification): ONE behavior
/// for every docked-panel divider.
///
/// The first pass grew two divergent handles — the sessions sidebar's
/// highlighted on hover but floated detached from the panel edge, while
/// the Files panel's sat flush but never highlighted. This widget carries
/// both halves of the contract:
///   - geometry — the hit surface is centered on the panel edge (the
///     caller positions it there), so the painted grip reads flush
///     against the panel, never detached;
///   - interaction — idle shows the hairline grip; hovering the divider
///     highlights it with the accent color; dragging hands the raw
///     horizontal delta to [onDragUpdate] (no behavior change mid-drag).
///
/// The hit surface itself stays transparent — the glass panels keep their
/// "no divider rail" contract; only the short grip paints.
class FaPaneResizeHandle extends StatefulWidget {
  const FaPaneResizeHandle({
    super.key,
    required this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
    this.width = 16,
    this.gripSize = const Size(3, 36),
  });

  /// Called with the horizontal delta of each drag update.
  final ValueChanged<double> onDragUpdate;

  /// Called when the drag gesture settles (pointer up) — e.g. the sessions
  /// sidebar persists the settled width once per gesture.
  final VoidCallback? onDragEnd;

  /// Called when the drag is interrupted (pointer cancel) — callers that
  /// treat cancel like settle pass the same callback to both.
  final VoidCallback? onDragCancel;

  /// The invisible hit surface's width; it straddles the panel edge so a
  /// few pixels of slop on either side still catch the pointer.
  final double width;

  /// The painted grip's size (the hover highlight target).
  final Size gripSize;

  @override
  State<FaPaneResizeHandle> createState() => _FaPaneResizeHandleState();
}

class _FaPaneResizeHandleState extends State<FaPaneResizeHandle> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) =>
            widget.onDragUpdate(details.delta.dx),
        onHorizontalDragEnd: widget.onDragEnd == null
            ? null
            : (_) => widget.onDragEnd!(),
        onHorizontalDragCancel: widget.onDragCancel == null
            ? null
            : () => widget.onDragCancel!(),
        child: AnimatedContainer(
          // The callers' tests find this surface to assert the idle
          // no-divider contract.
          key: const ValueKey('faPaneResizeHandleHitSurface'),
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          color: Colors.transparent,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: widget.gripSize.width,
              height: widget.gripSize.height,
              decoration: BoxDecoration(
                color: _hovering
                    ? tokens.accent.withValues(alpha: .8)
                    : tokens.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
