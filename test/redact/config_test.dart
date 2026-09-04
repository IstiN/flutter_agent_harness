import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:test/test.dart';

void main() {
  group('RedactionConfig defaults', () {
    test('scalars', () {
      const cfg = RedactionConfig();
      expect(cfg.enabled, isTrue);
      expect(cfg.blockMode, isFalse);
      expect(cfg.minEntropy, 4.5);
      expect(cfg.minLength, 32);
      expect(cfg.allowlistRegexes, isEmpty);
      expect(cfg.layerToggles, isEmpty);
    });

    test('layer toggles: pii off, everything else on', () {
      const cfg = RedactionConfig();
      for (final layer in RedactionLayer.values) {
        expect(
          cfg.isLayerEnabled(layer),
          layer != RedactionLayer.pii,
          reason: layer.name,
        );
      }
    });

    test('explicit toggles override defaults', () {
      const cfg = RedactionConfig(
        layerToggles: {RedactionLayer.pii: true, RedactionLayer.vendor: false},
      );
      expect(cfg.isLayerEnabled(RedactionLayer.pii), isTrue);
      expect(cfg.isLayerEnabled(RedactionLayer.vendor), isFalse);
      expect(cfg.isLayerEnabled(RedactionLayer.context), isTrue);
    });
  });

  group('RedactionConfig.fromJson', () {
    test('round-trips through toJson', () {
      final cfg = RedactionConfig(
        enabled: false,
        blockMode: true,
        layerToggles: {RedactionLayer.pii: true, RedactionLayer.entropy: false},
        allowlistRegexes: [RegExp(r'[0-9a-f]{40}'), RegExp(r'UUID-[0-9]+')],
        minEntropy: 3.25,
        minLength: 24,
      );
      final restored = RedactionConfig.fromJson(cfg.toJson());
      expect(restored, cfg);
      expect(restored.hashCode, cfg.hashCode);
    });

    test('null and unknown keys are ignored', () {
      final cfg = RedactionConfig.fromJson({
        'enabled': null,
        'blockMode': null,
        'minEntropy': null,
        'minLength': null,
        'layers': null,
        'allowlist': null,
        'totally_unknown': {'deep': true},
      });
      expect(cfg, const RedactionConfig());
    });

    test('unknown layer names and non-bool toggle values are ignored', () {
      final cfg = RedactionConfig.fromJson({
        'layers': {'vendor': false, 'bogus_layer': true, 'pii': 'yes'},
      });
      expect(cfg.isLayerEnabled(RedactionLayer.vendor), isFalse);
      expect(cfg.isLayerEnabled(RedactionLayer.pii), isFalse); // default
      expect(cfg.layerToggles, {RedactionLayer.vendor: false});
    });

    test('allowlist accepts pattern strings and skips junk entries', () {
      final cfg = RedactionConfig.fromJson({
        'allowlist': [r'[0-9a-f]{40}', 42, null],
      });
      expect(cfg.allowlistRegexes.map((r) => r.pattern), [r'[0-9a-f]{40}']);
    });

    test('null json yields defaults', () {
      expect(RedactionConfig.fromJson(null), const RedactionConfig());
    });
  });

  group('config honored by the pipeline', () {
    test('per-layer toggle disables a layer', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = RedactionPipeline(
        registeredSecrets: const [],
        config: RedactionConfig(layerToggles: {RedactionLayer.vendor: false}),
      );
      final matches = p.scan('tok $token end');
      expect(matches.where((m) => m.layer == RedactionLayer.vendor), isEmpty);
      expect(p.redact('tok $token end'), isNot(contains('GitHub Token')));
    });

    test('pii toggle opts in to PII masking', () {
      final p = RedactionPipeline(
        registeredSecrets: const [],
        config: const RedactionConfig(layerToggles: {RedactionLayer.pii: true}),
      );
      expect(p.redact('mail bob@example.co end'), 'mail [REDACTED:Email] end');
    });

    test('allowlist from JSON suppresses matches', () {
      const token = 'qZ3mK8vB2nR7xW4cJ9fT5gL0dP1sH6yU';
      final cfg = RedactionConfig.fromJson({
        'allowlist': [token],
      });
      final p = RedactionPipeline(registeredSecrets: const [], config: cfg);
      expect(p.scan('tok $token end'), isEmpty);
    });
  });
}
