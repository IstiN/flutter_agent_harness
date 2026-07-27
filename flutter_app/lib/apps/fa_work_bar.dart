// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/fa_mark.dart';

/// Compact "Fa is working" bar shown at the bottom of a JS app view while
/// the agent runs: an orbiting comet indicator around the Fa mark, a live
/// status line (current tool call / thinking / writing), a stop button, an
/// expand-to-chat button and an inline follow-up input — so the user keeps
/// steering without leaving the app.
///
/// The bar is also a pull handle: dragging it UP expands the chat overlay
/// (same action as the expand button, [onExpand]); dragging it DOWN fires
/// [onCollapse] so a host that shows the bar inside the expanded chat can
/// collapse back. The bar follows the finger and springs back unless the
/// drag passes the trigger threshold.
class FaWorkBar extends StatefulWidget {
  const FaWorkBar({
    super.key,
    required this.service,
    this.onSend,
    this.onExpand,
    this.onCollapse,
  });

  final AgentService service;

  /// Sends a follow-up message to the agent (text; the caller attaches the
  /// app state + screenshot when useful).
  final Future<void> Function(String text)? onSend;

  /// Opens the full chat (typically pops the app view). Also fired by a
  /// pull-up drag on the bar.
  final VoidCallback? onExpand;

  /// Collapses the expanded chat back to the app view. Fired by a
  /// pull-down drag on the bar; leave null where the bar is not hosted
  /// inside the expanded chat.
  final VoidCallback? onCollapse;

  @override
  State<FaWorkBar> createState() => _FaWorkBarState();
}

class _FaWorkBarState extends State<FaWorkBar>
    with SingleTickerProviderStateMixin {
  /// Travel (px) beyond which a release triggers expand/collapse.
  static const double _dragThreshold = 48;

  /// Fling velocity (px/s) that triggers expand/collapse on its own.
  static const double _flingVelocity = 300;

  /// How far the bar visually follows the finger before resisting.
  static const double _maxDragTravel = 120;

  late final AnimationController _orbit;
  final _inputController = TextEditingController();
  bool _sending = false;
  double _dragOffset = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    widget.service.addListener(_syncOrbit);
    _syncOrbit();
  }

  @override
  void didUpdateWidget(covariant FaWorkBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_syncOrbit);
      widget.service.addListener(_syncOrbit);
      _syncOrbit();
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_syncOrbit);
    _orbit.dispose();
    _inputController.dispose();
    super.dispose();
  }

  /// The comet orbits only while the agent streams; idle frames are static
  /// (and the bar hides itself anyway), so no ticker burns battery.
  void _syncOrbit() {
    if (widget.service.isStreaming) {
      if (!_orbit.isAnimating) _orbit.repeat();
    } else if (_orbit.isAnimating) {
      _orbit.stop();
      _orbit.value = 0;
    }
  }

  /// Test hook: lets widget tests assert the orbit spins only while
  /// streaming without reaching into private state.
  @visibleForTesting
  AnimationController get debugOrbitController => _orbit;

  String _statusText() {
    for (final message in widget.service.messages.reversed) {
      switch (message.role) {
        case 'system':
          return message.content.split('\n').first;
        case 'tool':
          return '[${message.toolName}] ✓';
        case 'thinking':
          return context.l10n.appsFaStatusThinking;
        case 'assistant':
          return context.l10n.appsFaStatusWriting;
      }
    }
    return context.l10n.appsFaStatusWorking;
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null || _sending) return;
    setState(() => _sending = true);
    try {
      _inputController.clear();
      await onSend(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    var next = _dragOffset + details.delta.dy;
    // Resist directions that have no action wired.
    if (widget.onExpand == null) next = next.clamp(0.0, double.infinity);
    if (widget.onCollapse == null) {
      next = next.clamp(double.negativeInfinity, 0.0);
    }
    setState(() {
      _dragging = true;
      _dragOffset = next.clamp(-_maxDragTravel, _maxDragTravel);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dragOffset <= -_dragThreshold || velocity <= -_flingVelocity) {
      widget.onExpand?.call();
    } else if (_dragOffset >= _dragThreshold || velocity >= _flingVelocity) {
      widget.onCollapse?.call();
    }
    _resetDrag();
  }

  void _resetDrag() {
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        if (!widget.service.isStreaming) return const SizedBox.shrink();
        // Theme-aware (FahColors): the bar is the COLLAPSED state of the
        // FaChatOverlay — same surface, border, and shadow language, so
        // light themes no longer get a dark bar and the two states read as
        // one component.
        final colors = FahColors.of(context);
        final canDrag = widget.onExpand != null || widget.onCollapse != null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: canDrag ? _onVerticalDragUpdate : null,
          onVerticalDragEnd: canDrag ? _onVerticalDragEnd : null,
          onVerticalDragCancel: canDrag ? _resetDrag : null,
          child: AnimatedContainer(
            duration: _dragging
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, _dragOffset, 0),
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colors.panelAlt.withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colors.border),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canDrag)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          key: const ValueKey('faWorkBarHandle'),
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.dim.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      FaOrbitIndicator(
                        key: const ValueKey('faWorkBarOrbit'),
                        animation: _orbit,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _statusText(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FahPalette.mono(
                            color: colors.dim,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.open_in_full, size: 16),
                        tooltip: context.l10n.appsOpenChatTooltip,
                        visualDensity: VisualDensity.compact,
                        color: colors.dim,
                        onPressed: widget.onExpand,
                      ),
                      IconButton(
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                        tooltip: context.l10n.appsStopTooltip,
                        visualDensity: VisualDensity.compact,
                        color: colors.error,
                        onPressed: widget.service.abort,
                      ),
                    ],
                  ),
                  if (widget.onSend != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputController,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: context.l10n.appsFollowUpHint,
                              hintStyle: TextStyle(
                                color: colors.dim,
                                fontSize: 13,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: colors.dim.withValues(alpha: 0.12),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                            onSubmitted: (_) => unawaited(_send()),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(Icons.send, size: 16),
                          tooltip: context.l10n.appsSendTooltip,
                          visualDensity: VisualDensity.compact,
                          color: colors.indigo,
                          onPressed: _sending ? null : () => unawaited(_send()),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// YoLoIT-style orbit indicator: a small indigo → teal ring with a comet
/// arc sweeping around the Fa mark (~1.2 s per turn, gradient tail fading
/// to transparent). Driven by an external [animation] so the host decides
/// when spinning starts and stops (the work bar spins it only while the
/// agent streams).
class FaOrbitIndicator extends StatelessWidget {
  const FaOrbitIndicator({super.key, required this.animation, this.size = 24});

  /// 0..1 repeating progress of one orbit turn.
  final Animation<double> animation;

  /// Outer diameter of the orbit ring.
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _OrbitPainter(animation.value)),
            ),
            FaMark(size: size * 0.45),
          ],
        ),
      ),
    );
  }
}

/// Paints the orbit ring plus the comet arc. The comet's head sits at the
/// bright teal end of a [SweepGradient] whose tail fades through indigo to
/// transparent; [progress] rotates the whole comet around the ring.
class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1.5;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Base ring: faint brand gradient.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = SweepGradient(
        colors: [
          FahPalette.indigo.withValues(alpha: 0.3),
          FahPalette.teal.withValues(alpha: 0.3),
          FahPalette.indigo.withValues(alpha: 0.3),
        ],
      ).createShader(rect);
    canvas.drawCircle(center, radius, ringPaint);

    // Comet arc: the sweep ends at gradient angle 0 (east), where the
    // shader is solid teal — the tail behind it fades to transparent.
    const sweep = math.pi * 1.6;
    final cometPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..shader = const SweepGradient(
        colors: [Colors.transparent, FahPalette.indigo, FahPalette.teal],
        stops: [0.0, 0.55, 1.0],
      ).createShader(rect);
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(progress * 2 * math.pi)
      ..translate(-center.dx, -center.dy)
      ..drawArc(rect, -sweep, sweep, false, cometPaint)
      ..restore();
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) => old.progress != progress;
}
