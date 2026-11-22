import 'package:fa/apps/app_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const curatedIds = [
    'health',
    'map',
    'weather',
    'voice-notes',
    'crypto',
    'fitness-trainer',
    'english-teacher',
    'yolo-hello',
    'stocks',
    'video-player',
    'animation-showcase',
  ];

  testWidgets('every curated app SVG parses and renders', (tester) async {
    for (final id in curatedIds) {
      final artwork = AppIconArtwork.svgFor(id);
      expect(
        artwork,
        isNotNull,
        reason: 'curated artwork registered for $id',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SvgPicture.string(artwork!, width: 64, height: 64),
          ),
        ),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'curated SVG for $id renders cleanly',
      );
    }
  });

  testWidgets('emoji-only manifests get a uniform gradient squircle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ),
    );
    final decoration = AppIconPalette.decoration(
      seed: 'some-emoji-app',
      brightness: Brightness.dark,
      size: 60,
    );
    expect(decoration.gradient, isNotNull);
  });
}
