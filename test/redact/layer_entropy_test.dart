import 'package:flutter_agent_harness/src/redact/layer_entropy.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

const _highEntropy = 'qZ3mK8vB2nR7xW4cJ9fT5gL0dP1sH6yU';

void main() {
  group('layerEntropy', () {
    test('long high-entropy token matches', () {
      const src = 'hash $_highEntropy end';
      final matches = layerEntropy(src, _cfg);
      expect(matches, hasLength(1));
      expect(
        src.substring(matches.single.start, matches.single.end),
        _highEntropy,
      );
      expect(matches.single.layer, RedactionLayer.entropy);
      expect(matches.single.kindLabel, highEntropyLabel);
    });

    test('low-entropy runs of the same length do not match', () {
      expect(layerEntropy('x ${'a' * 40} y', _cfg), isEmpty);
      expect(layerEntropy('x ${'aabbccdd' * 4} y', _cfg), isEmpty);
    });

    test('tokens shorter than minLength do not match', () {
      final short = _highEntropy.substring(0, 31);
      expect(layerEntropy('x $short y', _cfg), isEmpty);
    });

    test('custom minLength and minEntropy are honored', () {
      const cfg = RedactionConfig(minLength: 8, minEntropy: 3.0);
      const src = 'tok aB3xK9mQ end';
      final matches = layerEntropy(src, cfg);
      expect(matches, hasLength(1));
      expect(
        src.substring(matches.single.start, matches.single.end),
        'aB3xK9mQ',
      );
    });

    test('non-ASCII runs are skipped', () {
      expect(layerEntropy('секретныйтокenddd ${'ж' * 40}', _cfg), isEmpty);
    });

    test('tokens inside prior spans are skipped', () {
      final prior = [
        RedactionMatch(
          start: 5,
          end: 5 + _highEntropy.length,
          layer: RedactionLayer.pem,
          kindLabel: 'PEM PRIVATE KEY',
        ),
      ];
      expect(
        layerEntropy('hash $_highEntropy end', _cfg, prior: prior),
        isEmpty,
      );
    });

    test('empty and short texts yield nothing', () {
      expect(layerEntropy('', _cfg), isEmpty);
      expect(layerEntropy('tiny', _cfg), isEmpty);
    });
  });
}
