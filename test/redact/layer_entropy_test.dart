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

    test(
      'a filesystem path is never one entropy token (no slash gluing)',
      () async {
        // Constructed parts: a uuid filename plus a high-entropy-looking
        // directory segment. Whole-path tokenization (slash in the charset)
        // used to glue this into ONE >4.5-entropy token and shred every
        // ls/find/read listing.
        final uuid = '01a05ea4-c7fe-7cbe-9e93-1575eed34d59';
        final path =
            '/Users/x/Library/qZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL7eM3uQ9i'
            '/sessions/2026-09-01T23-24-12-542725_$uuid.jsonl';
        expect(layerEntropy('found $path in listing', _cfg), isEmpty);
        // The same token NOT preceded by a slash is a standalone value and
        // must still be caught.
        final seg = 'qZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL7eM3uQ9i';
        expect(layerEntropy('token $seg end', _cfg), hasLength(1));
      },
    );

    test('uuid and pure-hex tokens are structural, not secrets', () {
      expect(
        layerEntropy('id 01a05ea4-c7fe-7cbe-9e93-1575eed34d59 end', _cfg),
        isEmpty,
      );
      expect(
        layerEntropy('sha a3f5b2c8d71e94f60218b7cd45e6a190f83b27d4 end', _cfg),
        isEmpty,
      );
    });

    test('subresource-integrity hashes survive', () {
      const b64 = 'mg4aOJjqPBvUnLo0BWafbbTVBThScgeBAmBAJqDkxRYj0zOab';
      expect(layerEntropy('"integrity": "sha512-$b64"', _cfg), isEmpty);
      expect(layerEntropy('"integrity": "sha256-$b64"', _cfg), isEmpty);
    });

    test('a contextless high-entropy secret still matches', () {
      // 40 chars, mixed case + digits, alphabet >> 8, entropy > 4.5,
      // standalone (not a path component, not a known structure).
      const secret = 'qZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL7eM3uQ9i';
      final matches = layerEntropy('key $secret end', _cfg);
      expect(matches, hasLength(1));
      expect(matches.single.kindLabel, highEntropyLabel);
    });
  });
}
