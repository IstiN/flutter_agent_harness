import 'package:flutter_agent_example/gemma/gemma_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GemmaModelPreset platform resolution', () {
    test('web resolves the distinct `-web.litertlm` URL and install '
        'filename, mobile the plain ones', () {
      for (final preset in gemmaModelPresets) {
        // Web: the web build from the same HuggingFace repo, installed
        // under the web file name (the plugin keys installs by the URL
        // basename — this is what keeps a stale mobile-named OPFS entry
        // from satisfying the web install check).
        expect(preset.urlFor(isWeb: true), endsWith('-web.litertlm'));
        expect(
          preset.urlFor(isWeb: true),
          startsWith(preset.url.replaceAll(RegExp(r'[^/]+$'), '')),
          reason: 'web build lives in the same repo as the mobile one',
        );
        expect(
          preset.filenameFor(isWeb: true),
          preset.filename.replaceAll('.litertlm', '-web.litertlm'),
        );
        expect(preset.filenameFor(isWeb: true), isNot(preset.filename));

        // Mobile: unchanged URL and filename.
        expect(preset.urlFor(isWeb: false), preset.url);
        expect(preset.filenameFor(isWeb: false), preset.filename);
        expect(preset.url, isNot(endsWith('-web.litertlm')));
      }
      // The exact ids the user's stale OPFS entry and the fix hinge on.
      expect(
        gemmaModelPresets.first.filenameFor(isWeb: true),
        'gemma-4-E2B-it-web.litertlm',
      );
      expect(gemmaModelPresets.first.filename, 'gemma-4-E2B-it.litertlm');
    });

    test('size labels differ per platform (the web builds are smaller)', () {
      final e2b = gemmaModelPresets.first;
      expect(e2b.sizeLabelFor(isWeb: false), '~2.4 GB');
      expect(e2b.sizeLabelFor(isWeb: true), '~1.9 GB');
      final e4b = gemmaModelPresets.last;
      expect(e4b.sizeLabelFor(isWeb: false), '~4.3 GB');
      expect(e4b.sizeLabelFor(isWeb: true), '~2.8 GB');
    });

    test('a preset without web fields falls back to the mobile ones on '
        'web', () {
      const preset = GemmaModelPreset(
        id: 'test-model',
        displayName: 'Test',
        url: 'https://example.com/models/test-model.litertlm',
        filename: 'test-model.litertlm',
        sizeLabel: '~1 GB',
      );
      expect(preset.urlFor(isWeb: true), preset.url);
      expect(preset.filenameFor(isWeb: true), preset.filename);
      expect(preset.sizeLabelFor(isWeb: true), preset.sizeLabel);
    });
  });
}
