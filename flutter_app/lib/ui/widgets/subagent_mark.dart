// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

/// The subagent mark (issue #426 v2 design): a minimal branch/hierarchy
/// glyph — one parent node forking into two smaller child nodes, like a
/// git-branch mark stood upright. Stroke-drawn (2px strokes, round caps
/// and joins in the 24-unit coordinate space) so it stays crisp at the
/// sidebar's 11–14 px sizes, where a filled robot icon turned to mud.
///
/// [color] is passed by the caller ([FahColors] dim/teal) so the glyph
/// reads in both themes; the default suits either.
class SubagentMark extends StatelessWidget {
  const SubagentMark({super.key, this.size = 13, this.color});

  /// Square edge of the glyph.
  final double size;

  /// Stroke/fill color; defaults to a muted gray that reads on both the
  /// light and dark panel backgrounds.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SubagentMarkPainter(
        color: color ?? const Color(0xFF8B919E),
      ),
    );
  }
}

class _SubagentMarkPainter extends CustomPainter {
  _SubagentMarkPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final fill = Paint()..color = color;

    // Parent node (top center), then the trunk that forks into both
    // children — the tree reads top-down like the sidebar nests them.
    canvas.drawCircle(const Offset(12, 4.9), 2.4, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(12, 7.7)
        ..lineTo(12, 11)
        ..moveTo(12, 11)
        ..lineTo(7, 13.8)
        ..moveTo(12, 11)
        ..lineTo(17, 13.8),
      stroke,
    );
    // The two child nodes, filled to sit visually "under" the parent.
    canvas.drawCircle(const Offset(7, 17.2), 2, fill);
    canvas.drawCircle(const Offset(17, 17.2), 2, fill);
  }

  @override
  bool shouldRepaint(_SubagentMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
