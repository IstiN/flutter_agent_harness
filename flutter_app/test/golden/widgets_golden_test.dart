/// Golden coverage for the sidebar's SVG marks (see
/// `lib/ui/widgets/model_mark.dart`): rendered on the dark panel palette so
/// the gradient chip and dim sliders read exactly as in the model card.
library;

import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/model_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('ModelMark and TuneMark on the dark palette', (tester) async {
    await pumpGolden(
      tester,
      Container(
        width: 320,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: FahPalette.panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ModelMark(size: 32),
            SizedBox(width: 16),
            TuneMark(size: 24),
          ],
        ),
      ),
      size: goldenSizeTall,
    );
    await expectGolden(tester, 'model_marks');
  });
}
