// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';

/// The canonical B3-square-accent identity from `logos.html`.
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

/// Paints the canonical 68×68 B3-square-accent mark in any token palette.
class FaLogoPainter extends CustomPainter {
  const FaLogoPainter(this.tokens);

  final FaDesignTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 68, size.height / 68);

    final outer = RRect.fromLTRBR(4, 4, 64, 64, const Radius.circular(18));
    canvas.drawRRect(outer, Paint()..color = tokens.surface1);
    canvas.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = tokens.accent,
    );

    final chevron = Path()
      ..moveTo(15, 28)
      ..lineTo(22, 34)
      ..lineTo(15, 40);
    canvas.drawPath(chevron, _linePaint(tokens.accent, 2.8));

    // Deterministic vector Fa at the reference's x=27 / baseline=42 anchor.
    // The 22px bold text is geometry, so rendering never depends on host fonts.
    final f = Path()
      ..moveTo(27, 42)
      ..lineTo(27, 26)
      ..lineTo(38.5, 26);
    canvas.drawPath(f, _linePaint(tokens.ink1, 2.8));
    canvas.drawLine(
      const Offset(27, 33.5),
      const Offset(35.5, 33.5),
      _linePaint(tokens.ink1, 2.8),
    );
    canvas.drawCircle(
      const Offset(43, 36),
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = tokens.ink1,
    );
    canvas.drawLine(
      const Offset(48, 31),
      const Offset(48, 42),
      _linePaint(tokens.ink1, 2.6),
    );

    final dotColor = tokens.agentHues.length > 1
        ? tokens.agentHues[1]
        : tokens.accent;
    canvas.drawCircle(const Offset(48, 22), 3.2, Paint()..color = dotColor);
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
