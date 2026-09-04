// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'trajectory_controller.dart';
import 'trajectory_strings.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart' hide KeyEvent;

/// Horizontal geometry of the trajectory timeline (ported from the TS
/// trajectory timeline CSS): the label gutter, the three lanes, and the
/// interaction constants.
const double trajectoryTimelineLabelGutter = 44;
const double trajectoryTimelineLanesHeight = 36;
const double trajectoryTimelineLaneStride = 14;
const double trajectoryTimelineSpanHeight = 8;
const double trajectoryTimelineMinimumSpanPx = 2;

/// Zero-width spans render at this fixed width in `time` mode.
const double trajectoryTimelineTimeSpanPx = 8;
const double trajectoryTimelineMinimumDragPx = 3;
const double trajectoryTimelineEdgePanZoneFraction = 0.08;
const double trajectoryTimelineEdgePanStepFraction = 0.025;
const double trajectoryTimelineMaximumEdgePanPx = 32;
const Duration trajectoryTimelineTooltipDelay = Duration(milliseconds: 500);
const double trajectoryTimelineZoomFactorPerDelta = 0.0015;

/// A zoomed viewport collapses back to the full domain past this fraction
/// of it.
const double trajectoryTimelineZoomResetFraction = 0.999;

/// Visible window over the timeline domain; null viewport on the widget
/// means the [TrajectoryTimelineViewport.full] domain.
final class TrajectoryTimelineViewport {
  /// Creates a viewport over `[start, start + duration]`.
  const TrajectoryTimelineViewport({
    required this.start,
    required this.duration,
  });

  /// The full domain of [model]; a degenerate (zero-width) domain — every
  /// span anchored at one instant — falls back to a 1-unit window so the
  /// fraction math stays finite.
  factory TrajectoryTimelineViewport.full(TrajectoryTimelineModel model) =>
      TrajectoryTimelineViewport(
        start: model.start,
        duration: trajectoryTimelineFullDuration(model),
      );

  /// Inclusive domain value at the window's left edge.
  final double start;

  /// Domain units visible across the track.
  final double duration;

  /// Maps a domain value to a track-relative pixel offset.
  double toPx(double domain, double trackWidth) =>
      (domain - start) / duration * trackWidth;

  /// Maps a track-relative pixel offset to a domain value.
  double toDomain(double px, double trackWidth) =>
      start + px / trackWidth * duration;
}

/// The smallest zoom window in domain units: 4 record slots in sequence
/// mode, 20 ms on the timed projections.
double trajectoryTimelineMinimumZoom(
  TrajectoryTimelineModel model,
  TrajectoryTimelineMode mode,
) => mode == TrajectoryTimelineMode.sequence
    ? 4
    : math.min(20.0, trajectoryTimelineFullDuration(model));

/// The model's domain extent, never zero (see
/// [TrajectoryTimelineViewport.full]).
double trajectoryTimelineFullDuration(TrajectoryTimelineModel model) =>
    math.max(model.end - model.start, 1);

/// Clamps [viewport] inside [model] and above the mode's minimum zoom.
TrajectoryTimelineViewport trajectoryTimelineClampViewport(
  TrajectoryTimelineViewport viewport,
  TrajectoryTimelineModel model,
  TrajectoryTimelineMode mode,
) {
  final full = trajectoryTimelineFullDuration(model);
  final duration = viewport.duration
      .clamp(math.min(trajectoryTimelineMinimumZoom(model, mode), full), full)
      .toDouble();
  final start = viewport.start
      .clamp(model.start, model.end - duration)
      .toDouble();
  return TrajectoryTimelineViewport(start: start, duration: duration);
}

/// Wheel zoom: `duration *= exp(deltaY * k)` anchored at the cursor's
/// domain point; returns null when the zoom collapses to the full domain.
TrajectoryTimelineViewport? trajectoryTimelineZoomed({
  required TrajectoryTimelineViewport viewport,
  required double anchorPx,
  required double deltaY,
  required double trackWidth,
  required TrajectoryTimelineModel model,
  required TrajectoryTimelineMode mode,
}) {
  final anchor = viewport.toDomain(anchorPx, trackWidth);
  final full = trajectoryTimelineFullDuration(model);
  final raw =
      viewport.duration *
      math.exp(deltaY * trajectoryTimelineZoomFactorPerDelta);
  if (raw >= full * trajectoryTimelineZoomResetFraction) return null;
  // Clamp the window first, then keep the cursor's domain point fixed
  // under its pixel anchor.
  final duration = raw
      .clamp(math.min(trajectoryTimelineMinimumZoom(model, mode), full), full)
      .toDouble();
  final start = (anchor - anchorPx / trackWidth * duration)
      .clamp(model.start, model.end - duration)
      .toDouble();
  return TrajectoryTimelineViewport(start: start, duration: duration);
}

/// Right-drag pan: shift the window by [dxPx], clamped to the domain.
TrajectoryTimelineViewport trajectoryTimelinePanned({
  required TrajectoryTimelineViewport viewport,
  required double dxPx,
  required double trackWidth,
  required TrajectoryTimelineModel model,
  required TrajectoryTimelineMode mode,
}) => trajectoryTimelineClampViewport(
  TrajectoryTimelineViewport(
    start: viewport.start - dxPx / trackWidth * viewport.duration,
    duration: viewport.duration,
  ),
  model,
  mode,
);

/// The rendered [Rect] of [span]: lane row from the span's lane, horizontal
/// position from the viewport fraction, clamped to the minimum span width
/// (fixed width for zero-width spans in `time` mode).
Rect trajectoryTimelineSpanRect(
  TrajectoryTimelineSpan span, {
  required TrajectoryTimelineViewport viewport,
  required TrajectoryTimelineMode mode,
  required double trackWidth,
}) {
  final left = viewport.toPx(span.start, trackWidth);
  final right = viewport.toPx(span.end, trackWidth);
  final width = right > left
      ? math.max(right - left, trajectoryTimelineMinimumSpanPx)
      : (mode == TrajectoryTimelineMode.time
            ? trajectoryTimelineTimeSpanPx
            : trajectoryTimelineMinimumSpanPx);
  return Rect.fromLTWH(
    trajectoryTimelineLabelGutter + left,
    span.lane * trajectoryTimelineLaneStride,
    width,
    trajectoryTimelineSpanHeight,
  );
}

/// The TTFT share of an assistant's recorded generation time (used for the
/// two-band span split), or null when the timing is incomplete or
/// inconsistent (`stepStart <= firstToken <= completed` required).
double? trajectoryTimelineTtftFraction(TrajectoryRecord record) {
  if (record is! TrajectoryAssistantRecord) return null;
  final start = record.stepStartTime;
  final first = record.firstTokenTime;
  final completed = record.completedTime;
  if (start == null || first == null || completed == null) return null;
  if (first.isBefore(start) || completed.isBefore(first)) return null;
  final ttft = first.difference(start).inMilliseconds;
  final decoding = completed.difference(first).inMilliseconds;
  if (ttft + decoding <= 0) return null;
  return ttft / (ttft + decoding);
}

/// Wall-clock anchor and recorded duration of one record (the tooltip's
/// `Started` line), or a null anchor for untimed kinds.
(DateTime?, int?) trajectoryTimelineRecordTiming(TrajectoryRecord record) =>
    switch (record) {
      final TrajectoryAssistantRecord assistant => (
        assistant.stepStartTime,
        assistant.timeSeconds?.inMilliseconds,
      ),
      final TrajectoryToolRecord tool => (
        tool.startedAt,
        tool.timeSeconds?.inMilliseconds,
      ),
      final TrajectoryUserRecord user => (user.startedAt, null),
      final TrajectoryCompactedRecord compacted => (
        compacted.startedAt,
        compacted.timeSeconds?.inMilliseconds,
      ),
      final TrajectorySystemRecord system => (system.time, null),
      TrajectoryContextRecord() => (null, null),
    };

/// Span fills, reusing the ledger kind-pill tints.
// ponytail: duplicates the pill tint switch in trajectory_cell.dart; extract
// a shared kindTint(FahColors) helper when a third consumer appears.
Color _spanColor(TrajectoryCellKind kind, FahColors colors) => switch (kind) {
  TrajectoryCellKind.system => colors.dim,
  TrajectoryCellKind.user => colors.indigo,
  TrajectoryCellKind.context => colors.teal,
  TrajectoryCellKind.compacted => colors.dim,
  TrajectoryCellKind.message => colors.indigo,
  TrajectoryCellKind.tool => colors.pending,
  TrajectoryCellKind.subtool => colors.pending.withValues(alpha: 0.6),
};

/// Paints the timeline: lane labels, turn boundaries, spans (with the
/// assistant TTFT/decode split, selection/search dimming, hover and
/// selected rings), and the selection overlay.
class TrajectoryTimelinePainter extends CustomPainter {
  /// Creates a painter for one frame of timeline state.
  TrajectoryTimelinePainter({
    required this.model,
    required this.records,
    required this.mode,
    required this.colors,
    required this.laneLabels,
    this.fontFamily,
    this.viewport,
    this.selection,
    this.draft,
    this.dragging = false,
    this.hoverIndex,
    this.guideX,
    this.searchMatches,
    this.selectedRecordIndex,
  });

  /// The full-domain timeline model.
  final TrajectoryTimelineModel model;

  /// Ledger records (assistant TTFT/decode metrics), index-aligned with
  /// [TrajectoryTimelineSpan.index].
  final List<TrajectoryRecord> records;

  /// The active projection (time-mode zero-width rendering).
  final TrajectoryTimelineMode mode;

  /// Resolved palette.
  final FahColors colors;

  /// One label per lane: Input / Model / Tools.
  final List<String> laneLabels;

  /// Font family for the lane labels; null keeps the engine default.
  final String? fontFamily;

  /// The zoomed window, or null for the full domain.
  final TrajectoryTimelineViewport? viewport;

  /// The committed selection.
  final TrajectoryTimeRange? selection;

  /// The in-flight drag selection.
  final TrajectoryTimeRange? draft;

  /// Whether a drag selection is in flight (draft overlay emphasis).
  final bool dragging;

  /// Hovered span's ledger index.
  final int? hoverIndex;

  /// Track-relative pixel of the whitespace guide line.
  final double? guideX;

  /// Ledger indexes matching the active search; null when search is off.
  final Set<int>? searchMatches;

  /// Ledger index of the selected record.
  final int? selectedRecordIndex;

  TrajectoryTimelineViewport get _viewport =>
      viewport ?? TrajectoryTimelineViewport.full(model);

  Rect _rect(TrajectoryTimelineSpan span, double trackWidth) =>
      trajectoryTimelineSpanRect(
        span,
        viewport: _viewport,
        mode: mode,
        trackWidth: trackWidth,
      );

  bool _overlaps(TrajectoryTimelineSpan span, TrajectoryTimeRange range) =>
      span.start <= range.end && span.end >= range.start;

  double _opacity(TrajectoryTimelineSpan span) {
    if (span.index == hoverIndex || span.index == selectedRecordIndex) {
      return 1;
    }
    if (selection != null && !_overlaps(span, selection!)) return 0.2;
    final matches = searchMatches;
    if (matches != null && !matches.contains(span.index)) return 0.14;
    return 1;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final trackWidth = math.max(
      0.0,
      size.width - trajectoryTimelineLabelGutter,
    );
    _paintLaneLabels(canvas);
    _paintTurnBoundaries(canvas, trackWidth);
    final guide = guideX;
    if (hoverIndex == null && guide != null) {
      canvas.drawLine(
        Offset(trajectoryTimelineLabelGutter + guide, 0),
        Offset(
          trajectoryTimelineLabelGutter + guide,
          trajectoryTimelineLanesHeight,
        ),
        Paint()
          ..color = colors.borderBright.withValues(alpha: 0.6)
          ..strokeWidth = 2,
      );
    }
    for (final span in model.spans) {
      _paintSpan(canvas, span, trackWidth);
    }
    if (selection != null) {
      _paintSelection(canvas, selection!, trackWidth, 0.12);
    }
    if (dragging && draft != null) {
      _paintSelection(canvas, draft!, trackWidth, 0.18);
    }
  }

  void _paintLaneLabels(Canvas canvas) {
    final maxWidth = trajectoryTimelineLabelGutter - 8;
    for (var lane = 0; lane < laneLabels.length; lane++) {
      final painter = TextPainter(
        text: TextSpan(
          text: laneLabels[lane],
          style: TextStyle(
            color: colors.dim,
            fontSize: 9,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);
      painter.paint(
        canvas,
        Offset(
          maxWidth - painter.width,
          lane * trajectoryTimelineLaneStride +
              trajectoryTimelineSpanHeight / 2 -
              painter.height / 2,
        ),
      );
    }
  }

  void _paintTurnBoundaries(Canvas canvas, double trackWidth) {
    final paint = Paint()
      ..color = colors.border
      ..strokeWidth = 0.5;
    for (final boundary in model.turnBoundaries) {
      if (boundary.time <= model.start) continue;
      final x =
          trajectoryTimelineLabelGutter +
          _viewport.toPx(boundary.time, trackWidth);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, trajectoryTimelineLanesHeight),
        paint,
      );
    }
  }

  void _paintSpan(
    Canvas canvas,
    TrajectoryTimelineSpan span,
    double trackWidth,
  ) {
    final rect = _rect(span, trackWidth);
    final base = span.isError ? colors.error : _spanColor(span.kind, colors);
    final opacity = _opacity(span);
    final record = span.index >= 1 && span.index <= records.length
        ? records[span.index - 1]
        : null;
    final ttft = record == null ? null : trajectoryTimelineTtftFraction(record);
    if (ttft != null && rect.width > trajectoryTimelineMinimumSpanPx * 2) {
      final head = rect.width * ttft;
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.top, head, rect.height),
        Paint()
          ..color = Color.lerp(
            base,
            colors.bg,
            0.45,
          )!.withValues(alpha: opacity),
      );
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left + head,
          rect.top,
          rect.width - head,
          rect.height,
        ),
        Paint()..color = base.withValues(alpha: opacity),
      );
    } else {
      canvas.drawRect(rect, Paint()..color = base.withValues(alpha: opacity));
    }
    if (span.index == hoverIndex && span.index != selectedRecordIndex) {
      _ring(canvas, rect, colors.borderBright);
    }
    if (span.index == selectedRecordIndex) {
      _ring(canvas, rect, colors.indigo);
    }
  }

  void _ring(Canvas canvas, Rect rect, Color color) {
    canvas.drawRect(
      rect.inflate(1.5),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _paintSelection(
    Canvas canvas,
    TrajectoryTimeRange range,
    double trackWidth,
    double fillAlpha,
  ) {
    final left =
        trajectoryTimelineLabelGutter + _viewport.toPx(range.start, trackWidth);
    final right =
        trajectoryTimelineLabelGutter + _viewport.toPx(range.end, trackWidth);
    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, trajectoryTimelineLanesHeight),
      Paint()..color = colors.indigo.withValues(alpha: fillAlpha),
    );
    final bar = Paint()..color = colors.indigo;
    canvas.drawRect(
      Rect.fromLTWH(left - 1.5, 0, 3, trajectoryTimelineLanesHeight),
      bar,
    );
    canvas.drawRect(
      Rect.fromLTWH(right - 1.5, 0, 3, trajectoryTimelineLanesHeight),
      bar,
    );
  }

  @override
  bool shouldRepaint(TrajectoryTimelinePainter oldDelegate) =>
      oldDelegate.model != model ||
      oldDelegate.records != records ||
      oldDelegate.mode != mode ||
      oldDelegate.colors != colors ||
      oldDelegate.laneLabels != laneLabels ||
      oldDelegate.fontFamily != fontFamily ||
      oldDelegate.viewport != viewport ||
      oldDelegate.selection != selection ||
      oldDelegate.draft != draft ||
      oldDelegate.dragging != dragging ||
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.guideX != guideX ||
      oldDelegate.searchMatches != searchMatches ||
      oldDelegate.selectedRecordIndex != selectedRecordIndex;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);
}

/// The trajectory timeline strip: a three-lane [CustomPainter] over the
/// controller's timeline model with wheel zoom, right-drag pan, drag
/// selection, hover tooltips, and search/selection dimming.
///
/// Geometry: a 44px label gutter (Input / Model / Tools), a 36px lanes
/// area, spans at `lane * 14px` with an 8px height. A null
/// [TrajectoryController.timelineModel] renders a "No timing data"
/// placeholder.
class TrajectoryTimeline extends StatefulWidget {
  /// Creates a timeline bound to [controller].
  const TrajectoryTimeline({
    super.key,
    required this.controller,
    this.height = 50,
  });

  /// The controller holding the timeline model and interaction state.
  final TrajectoryController controller;

  /// Total strip height (lanes occupy the top 36px).
  final double height;

  @override
  State<TrajectoryTimeline> createState() => _TrajectoryTimelineState();
}

class _TrajectoryTimelineState extends State<TrajectoryTimeline> {
  TrajectoryTimelineViewport? _viewport;
  TrajectoryTimelineModel? _viewportModel;
  int? _hoverIndex;
  double? _guideX;
  int? _tooltipIndex;
  bool _dragging = false;
  double? _pressX;
  double? _draftStart;
  double? _draftEnd;
  bool _rightDown = false;
  double? _panX;
  double _edgePanDirection = 0;
  double _edgePanStrength = 0;
  double _trackWidth = 0;
  Timer? _tooltipTimer;
  Timer? _edgePanTimer;
  final FocusNode focusNode = FocusNode();

  TrajectoryController get _controller => widget.controller;

  TrajectoryTimelineMode get _mode => _controller.timelineMode;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(TrajectoryTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      _controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _tooltipTimer?.cancel();
    _edgePanTimer?.cancel();
    focusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  TrajectoryTimelineViewport get _effectiveViewport =>
      _viewport ?? TrajectoryTimelineViewport.full(_viewportModel!);

  double get _minimumSelection {
    final model = _viewportModel!;
    final spanCount = model.spans.length;
    final full = model.end - model.start;
    return math.min(
      _effectiveViewport.duration,
      spanCount > 0 ? full / spanCount : full,
    );
  }

  double _trackDomain(double x) => _effectiveViewport.toDomain(
    (x - trajectoryTimelineLabelGutter).clamp(0.0, _trackWidth),
    _trackWidth,
  );

  double _clampDomain(double value) {
    final viewport = _effectiveViewport;
    return value.clamp(viewport.start, viewport.start + viewport.duration);
  }

  TrajectoryTimeRange _centeredRange(double center, double width) {
    final viewport = _effectiveViewport;
    final start = (center - width / 2).clamp(
      viewport.start,
      viewport.start + viewport.duration - width,
    );
    return TrajectoryTimeRange(start: start, end: start + width);
  }

  TrajectoryTimelineSpan? _spanAt(double x, double y) {
    final model = _viewportModel;
    if (model == null || y >= trajectoryTimelineLanesHeight) return null;
    for (final span in model.spans) {
      final rect = trajectoryTimelineSpanRect(
        span,
        viewport: _effectiveViewport,
        mode: _mode,
        trackWidth: _trackWidth,
      );
      if (x >= rect.left - 1 && x <= rect.right + 1) return span;
    }
    return null;
  }

  int _nearestIndex(double domain) {
    final model = _viewportModel!;
    var best = model.spans.first.index;
    var bestDistance = double.infinity;
    for (final span in model.spans) {
      final distance = ((span.start + span.end) / 2 - domain).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = span.index;
      }
    }
    return best;
  }

  // -- Pointer handling ---------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    final model = _viewportModel;
    if (model == null) return;
    focusNode.requestFocus();
    final x = event.localPosition.dx;
    if (event.buttons == kSecondaryButton) {
      _rightDown = true;
      // Pan only applies while zoomed; otherwise the release clears.
      _panX = _viewport != null ? x : null;
      return;
    }
    if (event.buttons != kPrimaryButton) return;
    _pressX = x;
    _dragging = true;
    final domain = _trackDomain(x);
    _draftStart = domain;
    _draftEnd = domain;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final model = _viewportModel;
    if (model == null) return;
    final x = event.localPosition.dx;
    if (_panX != null) {
      final dx = x - _panX!;
      _panX = x;
      setState(() {
        _viewport = trajectoryTimelinePanned(
          viewport: _effectiveViewport,
          dxPx: dx,
          trackWidth: _trackWidth,
          model: model,
          mode: _mode,
        );
      });
      return;
    }
    if (!_dragging) return;
    setState(() => _draftEnd = _trackDomain(x));
    _updateEdgePan(x);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_rightDown) {
      final panned = _panX != null;
      _rightDown = false;
      _panX = null;
      if (!panned) _controller.setTimelineSelection(null);
      return;
    }
    final model = _viewportModel;
    if (!_dragging || model == null) return;
    _stopEdgePan();
    _dragging = false;
    final x = event.localPosition.dx;
    final y = event.localPosition.dy;
    final moved =
        _pressX != null &&
        (x - _pressX!).abs() >= trajectoryTimelineMinimumDragPx;
    _pressX = null;
    final draftStart = _draftStart;
    final draftEnd = _draftEnd;
    _draftStart = null;
    _draftEnd = null;
    if (!moved) {
      final span = _spanAt(x, y);
      if (span != null) {
        final record = _controller.records[span.index - 1];
        _controller.setTimelineSelection(null);
        _controller.selectRecord(record.recordId);
        _controller.focusRecord(span.index);
      } else {
        final center = _trackDomain(x);
        _controller.setTimelineSelection(
          _centeredRange(center, _minimumSelection),
        );
        _controller.focusRecord(_nearestIndex(center));
      }
    } else if (draftStart != null && draftEnd != null) {
      var start = draftStart;
      var end = draftEnd;
      if (end < start) (start, end) = (end, start);
      final minimum = _minimumSelection;
      if (end - start < minimum) {
        final mid = (start + end) / 2;
        start = mid - minimum / 2;
        end = mid + minimum / 2;
      }
      _controller.setTimelineSelection(
        _centeredRange((start + end) / 2, end - start),
      );
    }
    setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _rightDown = false;
    _panX = null;
    _stopEdgePan();
    _dragging = false;
    _pressX = null;
    _draftStart = null;
    _draftEnd = null;
    if (mounted) setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent event) {
    final model = _viewportModel;
    if (model == null || event is! PointerScrollEvent) return;
    final viewport = trajectoryTimelineZoomed(
      viewport: _effectiveViewport,
      anchorPx: (event.localPosition.dx - trajectoryTimelineLabelGutter).clamp(
        0.0,
        _trackWidth,
      ),
      deltaY: event.scrollDelta.dy,
      trackWidth: _trackWidth,
      model: model,
      mode: _mode,
    );
    setState(() => _viewport = viewport);
  }

  // -- Edge auto-pan (zoomed drag) -----------------------------------------

  void _updateEdgePan(double x) {
    final model = _viewportModel;
    if (model == null || _viewport == null || !_dragging) {
      _stopEdgePan();
      return;
    }
    final zone = math.min(
      trajectoryTimelineMaximumEdgePanPx,
      _trackWidth * trajectoryTimelineEdgePanZoneFraction,
    );
    final trackX = (x - trajectoryTimelineLabelGutter).clamp(0.0, _trackWidth);
    double direction = 0;
    var strength = 0.0;
    if (zone > 0 && trackX < zone) {
      direction = -1;
      strength = 1 - trackX / zone;
    } else if (zone > 0 && trackX > _trackWidth - zone) {
      direction = 1;
      strength = 1 - (_trackWidth - trackX) / zone;
    }
    _edgePanDirection = direction;
    _edgePanStrength = strength.clamp(0.0, 1.0);
    if (direction == 0) {
      _edgePanTimer?.cancel();
      _edgePanTimer = null;
      return;
    }
    _edgePanTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _edgePanTick(),
    );
  }

  void _edgePanTick() {
    final model = _viewportModel;
    if (model == null || _viewport == null || !_dragging) {
      _stopEdgePan();
      return;
    }
    final step =
        _viewport!.duration *
        trajectoryTimelineEdgePanStepFraction *
        _edgePanStrength *
        _edgePanDirection;
    setState(() {
      _viewport = trajectoryTimelineClampViewport(
        TrajectoryTimelineViewport(
          start: _viewport!.start + step,
          duration: _viewport!.duration,
        ),
        model,
        _mode,
      );
      if (_draftEnd != null) _draftEnd = _clampDomain(_draftEnd! + step);
    });
  }

  void _stopEdgePan() {
    _edgePanTimer?.cancel();
    _edgePanTimer = null;
    _edgePanDirection = 0;
    _edgePanStrength = 0;
  }

  // -- Hover + tooltip -----------------------------------------------------

  void _onHover(PointerEvent event) {
    final model = _viewportModel;
    if (model == null) return;
    final x = event.localPosition.dx;
    final y = event.localPosition.dy;
    final span = _spanAt(x, y);
    setState(() {
      _hoverIndex = span?.index;
      _guideX =
          span == null &&
              y < trajectoryTimelineLanesHeight &&
              x >= trajectoryTimelineLabelGutter
          ? (x - trajectoryTimelineLabelGutter).clamp(0.0, _trackWidth)
          : null;
    });
    final index = span?.index;
    if (index == _tooltipIndex) return;
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
    _tooltipIndex = null;
    if (index != null) {
      _tooltipTimer = Timer(trajectoryTimelineTooltipDelay, () {
        if (mounted) setState(() => _tooltipIndex = index);
      });
    }
  }

  void _onExit(PointerEvent event) {
    _tooltipTimer?.cancel();
    _tooltipTimer = null;
    _stopEdgePan();
    setState(() {
      _hoverIndex = null;
      _guideX = null;
      _tooltipIndex = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _controller.setTimelineSelection(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -- Build ----------------------------------------------------------------

  Widget? _buildTooltip(BoxConstraints constraints) {
    final index = _tooltipIndex;
    final model = _viewportModel;
    if (index == null || model == null) return null;
    TrajectoryTimelineSpan? span;
    for (final candidate in model.spans) {
      if (candidate.index == index) span = candidate;
    }
    if (span == null || index > _controller.records.length) return null;
    final strings = TrajectoryStrings.of(context);
    final colors = FahColors.of(context);
    final record = _controller.records[index - 1];
    final rows = <String>[
      switch (record.kind) {
        TrajectoryCellKind.system => strings.kindSystem,
        TrajectoryCellKind.user => strings.kindUser,
        TrajectoryCellKind.context => strings.kindContext,
        TrajectoryCellKind.compacted => strings.kindCompacted,
        TrajectoryCellKind.message => strings.kindAssistant,
        TrajectoryCellKind.tool => strings.kindTool,
        TrajectoryCellKind.subtool => strings.kindSubtool,
      },
    ];
    final (startedAt, durationMs) = trajectoryTimelineRecordTiming(record);
    if (startedAt != null) {
      final end = durationMs != null && durationMs > 0
          ? ' → ${_clock(startedAt.add(Duration(milliseconds: durationMs)))}'
          : '';
      rows.add(strings.timelineStarted('${_clock(startedAt)}$end'));
    } else {
      rows.add(strings.timingStarted);
    }
    if (record is TrajectoryAssistantRecord &&
        trajectoryTimelineTtftFraction(record) != null) {
      final total = record.completedTime!
          .difference(record.stepStartTime!)
          .inMilliseconds;
      final first = record.firstTokenTime!
          .difference(record.stepStartTime!)
          .inMilliseconds;
      final decoding = total - first;
      rows.add(
        '${strings.timelineTotal(formatTimelineOffset(total.toDouble()))}'
        ' · '
        '${strings.timelineTtftDecoding(formatTimelineOffset(first.toDouble()), formatTimelineOffset(decoding.toDouble()))}',
      );
    }
    final rect = trajectoryTimelineSpanRect(
      span,
      viewport: _effectiveViewport,
      mode: _mode,
      trackWidth: _trackWidth,
    );
    final left = (rect.center.dx + 8)
        .clamp(0.0, math.max(0.0, constraints.maxWidth - 280))
        .toDouble();
    return Positioned(
      left: left,
      top: 0,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.panelAlt,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in rows)
              Text(
                row,
                style: TextStyle(color: colors.text, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final model = controller.timelineModel;
    final strings = TrajectoryStrings.of(context);
    final colors = FahColors.of(context);
    // Re-clamp a stored viewport when the snapshot changed the domain.
    if (!identical(_viewportModel, model)) {
      _viewportModel = model;
      if (_viewport != null && model != null) {
        _viewport = trajectoryTimelineClampViewport(_viewport!, model, _mode);
      }
    }
    final placeholder = Center(
      child: Text(
        strings.timelineNoTimingData,
        style: TextStyle(color: colors.dim, fontSize: 11),
      ),
    );
    return Semantics(
      container: true,
      label: strings.timelineAria,
      child: Focus(
        focusNode: focusNode,
        onKeyEvent: _onKey,
        child: SizedBox(
          height: widget.height,
          child: model == null
              ? placeholder
              : LayoutBuilder(
                  builder: (context, constraints) {
                    _trackWidth = math.max(
                      0.0,
                      constraints.maxWidth - trajectoryTimelineLabelGutter,
                    );
                    final selectedId = controller.selectedRecordId;
                    int? selectedIndex;
                    for (final record in controller.records) {
                      if (record.recordId == selectedId) {
                        selectedIndex = record.index;
                      }
                    }
                    final draft =
                        _dragging && _draftStart != null && _draftEnd != null
                        ? TrajectoryTimeRange(
                            start: math.min(_draftStart!, _draftEnd!),
                            end: math.max(_draftStart!, _draftEnd!),
                          )
                        : null;
                    final painter = TrajectoryTimelinePainter(
                      model: model,
                      records: controller.records,
                      mode: _mode,
                      colors: colors,
                      laneLabels: [
                        strings.usageInput,
                        strings.detailsModel,
                        strings.tabTools,
                      ],
                      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                      viewport: _viewport,
                      selection: controller.timelineSelection,
                      draft: draft,
                      dragging: _dragging,
                      hoverIndex: _hoverIndex,
                      guideX: _guideX,
                      searchMatches: controller.searchMatchRecordIds == null
                          ? null
                          : controller.searchMatchIndexes,
                      selectedRecordIndex: selectedIndex,
                    );
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: MouseRegion(
                            onHover: _onHover,
                            onExit: _onExit,
                            child: Listener(
                              onPointerDown: _onPointerDown,
                              onPointerMove: _onPointerMove,
                              onPointerUp: _onPointerUp,
                              onPointerCancel: _onPointerCancel,
                              onPointerSignal: _onPointerSignal,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onDoubleTap: () =>
                                    controller.setTimelineSelection(null),
                                child: CustomPaint(
                                  size: Size.infinite,
                                  painter: painter,
                                ),
                              ),
                            ),
                          ),
                        ),
                        ?_buildTooltip(constraints),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// `HH:mm:ss.mmm` wall-clock label used by span tooltips.
String _clock(DateTime time) {
  String pad2(int value) => value.toString().padLeft(2, '0');
  final millis = time.millisecond.toString().padLeft(3, '0');
  return '${pad2(time.hour)}:${pad2(time.minute)}:${pad2(time.second)}.$millis';
}
