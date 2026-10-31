// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';

/// The owner-approved Squircle-V2 identity from `logos.html`.
///
/// This is a vector painting, not a font glyph or raster asset: app icon,
/// launcher mark and compact brand header therefore share the exact geometry.
class FaLogo extends StatelessWidget {
  const FaLogo({super.key, this.size = 64, this.semanticLabel = 'Fa'});

  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: FaLogoPainter(FaDesignTokens.of(context))),
    ),
  );
}

/// Paints the canonical 84×84 Fa mark in any [FaDesignTokens] palette.
class FaLogoPainter extends CustomPainter {
  const FaLogoPainter(this.tokens);

  final FaDesignTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 84, size.height / 84);
    final outerRadius = tokens.direction == FaVisualDirection.graphite
        ? 18.0
        : 22.0;
    final outerFill = tokens.direction == FaVisualDirection.glass
        ? Color.lerp(tokens.surface1, tokens.accent, .09)!
        : tokens.surface1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(4, 4, 76, 76),
        Radius.circular(outerRadius),
      ),
      Paint()..color = outerFill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(4, 4, 76, 76),
        Radius.circular(outerRadius),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = tokens.hairline,
    );

    final bubble = Path()
      ..moveTo(20, 22)
      ..lineTo(64, 22)
      ..arcToPoint(const Offset(72, 30), radius: const Radius.circular(8))
      ..lineTo(72, 46)
      ..arcToPoint(const Offset(64, 54), radius: const Radius.circular(8))
      ..lineTo(38, 54)
      ..lineTo(26, 62)
      ..lineTo(26, 54)
      ..lineTo(20, 54)
      ..arcToPoint(const Offset(12, 46), radius: const Radius.circular(8))
      ..lineTo(12, 30)
      ..arcToPoint(
        const Offset(20, 22),
        radius: const Radius.circular(8),
        clockwise: true,
      )
      ..close();
    final bubbleFill = tokens.direction == FaVisualDirection.glass
        ? tokens.surface2.withValues(alpha: .84)
        : tokens.surface2;
    canvas.drawPath(bubble, Paint()..color = bubbleFill);
    canvas.drawPath(
      bubble,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 1.8
        ..color = tokens.accent,
    );

    final prompt = Path()
      ..moveTo(52, 28)
      ..lineTo(57, 33)
      ..lineTo(52, 38);
    canvas.drawPath(prompt, _linePaint(tokens.accent, 2));
    canvas.drawLine(
      const Offset(59, 38),
      const Offset(63, 38),
      _linePaint(tokens.accent, 2),
    );

    // Dominant vector Fa, matching the 22px bold reference without a font.
    canvas.save();
    canvas.translate(24, 26);
    canvas.scale(.72);
    canvas.drawPath(
      Path()
        ..moveTo(0, 28)
        ..lineTo(0, 0)
        ..lineTo(16, 0),
      _linePaint(tokens.ink1, 3.5),
    );
    canvas.drawLine(
      const Offset(0, 12.5),
      const Offset(12, 12.5),
      _linePaint(tokens.ink1, 3.5),
    );
    canvas.restore();

    canvas.save();
    canvas.translate(38, 31);
    canvas.scale(.82);
    canvas.drawCircle(
      const Offset(7, 11),
      6.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = tokens.ink1,
    );
    canvas.drawLine(
      const Offset(13.5, 4.5),
      const Offset(13.5, 17.5),
      _linePaint(tokens.ink1, 3),
    );
    canvas.restore();

    final dotColor = tokens.agentHues.length > 1
        ? tokens.agentHues[1]
        : tokens.accent;
    canvas.drawCircle(const Offset(60, 46), 3, Paint()..color = dotColor);
    canvas.restore();
  }

  static Paint _linePaint(Color color, double width) => Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = width
    ..color = color;

  @override
  bool shouldRepaint(covariant FaLogoPainter oldDelegate) =>
      oldDelegate.tokens != tokens;
}
