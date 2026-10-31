import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('all styleguide font presets render real bundled glyphs', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      Scaffold(
        appBar: AppBar(title: const Text('Fa 2.0 · Typography')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            for (final preset in FaFontPreset.values) ...[
              _PresetCard(preset: preset),
              if (preset != FaFontPreset.values.last)
                const SizedBox(height: 12),
            ],
          ],
        ),
      ),
      size: const Size(900, 1000),
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
        fontPreset: FaFontPreset.inter,
      ),
      wrap: (child) => child,
    );

    await expectGolden(tester, 'fa2_typography_presets');
  });
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset});

  final FaFontPreset preset;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
        fontPreset: preset,
      ),
      child: Builder(
        builder: (context) {
          final type = FaTypography.of(context);
          return FaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (preset) {
                  FaFontPreset.system => 'System SF',
                  FaFontPreset.geist => 'Geist',
                  FaFontPreset.jakarta => 'Plus Jakarta Sans',
                  FaFontPreset.inter => 'Inter',
                  FaFontPreset.outfit => 'Outfit + Inter',
                }, style: type.title),
                const SizedBox(height: 10),
                Text(
                  'The quick brown fox · Съешь ещё этих мягких булок.',
                  style: type.body,
                ),
                const SizedBox(height: 8),
                Text('Interface label · 13.5/19', style: type.label),
                const SizedBox(height: 6),
                Text('16,384 tokens · 42 ms · 0123456789', style: type.mono),
              ],
            ),
          );
        },
      ),
    );
  }
}
