// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

/// A deck of two chat bubbles: a dimmer one behind and the current
/// conversation in front with a speech tail and three typing dots.
class SessionsGlyph extends StatelessWidget {
  const SessionsGlyph({
    super.key,
    required this.color,
    required this.background,
    this.size = 22,
  });

  /// The stroke color of the front bubble and typing dots.
  final Color color;

  /// The fill of the front bubble — pass the surface the glyph sits on so
  /// the back bubble's edge does not show through.
  final Color background;

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _SessionsGlyphPainter(color, background),
    );
  }
}

class _SessionsGlyphPainter extends CustomPainter {
  const _SessionsGlyphPainter(this.color, this.background);

  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    // Approved variant A4b «Modern pair + dots»: a front typing bubble
    // over a half-visible back bubble on a 24x24 design grid.
    canvas.save();
    canvas.scale(size.width / 24);
    final back = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color.withValues(alpha: 0.55);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(9.2, 2.6, 12.2, 9.8),
        const Radius.circular(4.2),
      ),
      back,
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final front = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4.6, 5.6, 14.8, 9.8),
      const Radius.circular(4.2),
    );
    canvas.drawRRect(front, Paint()..color = background);
    canvas.drawRRect(front, stroke);
    canvas.drawPath(
      Path()
        ..moveTo(8.6, 15.2)
        ..lineTo(6.9, 19.1)
        ..lineTo(12.7, 15.2),
      stroke,
    );
    final dots = Paint()..color = color;
    for (final x in const [8.8, 12.0, 15.2]) {
      canvas.drawCircle(Offset(x, 10.5), 0.6, dots);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SessionsGlyphPainter old) =>
      old.color != color || old.background != background;
}
