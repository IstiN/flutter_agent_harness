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

  group('define / assignment carve-out (gh-1952 I3 / AC3)', () {
    // A define argument is ONE entropy token (the charset includes `=`
    // and `-`), so `--dart-define=JSR_THREE_EXAMPLE=webgl_geometry_colors`
    // crossed the threshold and got masked — the incident behind gh-1952.
    // Ordinary compile-time defines are not secrets: the SHAPE is exempt
    // from the entropy heuristic. Real secret layers (registered, vendor,
    // context, ...) outrank the carve-out and still match inside defines.
    const defines = <String>[
      // The exact incident shape: long flag, uppercase-snake key, plain
      // lowercase value, > 32 token chars total.
      'flutter test --dart-define=JSR_THREE_EXAMPLE=webgl_geometry_colors',
      // Short flag spelling.
      'flutter build apk -DJSR_THREE_EXAMPLE=webgl_geometry_colors',
      // Bare env-style assignment in a bash command.
      'DEF=webgl_geometry_colors_lightsphysicallycorrect',
      // Quoted value: the in-quote run is still an assignment shape.
      'flutter test --dart-define="JSR_THREE_EXAMPLE=webgl_geometry_colors"',
      // Long option with the value in the next shell word.
      'flutter test --dart-define JSR_THREE_EXAMPLE=webgl_geometry_colors',
      // Dotted flutter define key.
      'flutter run --dart-define=flutter.inspector.structuredErrorsValue=trueX',
    ];

    test('define shapes never match the entropy layer', () {
      for (final command in defines) {
        expect(
          layerEntropy(command, _cfg),
          isEmpty,
          reason: 'define must stay clean: $command',
        );
      }
    });

    test('a standalone high-entropy value without an assignment '
        'shape still matches', () {
      // The carve-out is shape-based: without a K=V / flag shape the
      // heuristic keeps working (regression guard against over-carving).
      const secret = 'qZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL7eM3uQ9i';
      expect(layerEntropy('key $secret end', _cfg), hasLength(1));
    });

    test('a define key alone (no =) is not carved out', () {
      // `--dart-define` requires K=V; a bare long flag run stays subject
      // to the heuristic.
      const arg = '--dart-defineqZ3mR7kW9pX2vB5nT8yC4jF6hD1sG0aL';
      expect(layerEntropy('x $arg y', _cfg), hasLength(1));
    });
  });
  group('carve-out must not silence the entropy net (gh-1952 review)', () {
    // Review of the first cut: the bare `K=V` exemption branch matched
    // ANY token containing `=`, so the two most common secret encodings
    // lost their last-resort net — this layer also runs on the display/
    // persistence pipeline where tool OUTPUT flows through.
    test('a padded-base64 secret is still entropy-masked', () {
      // 37 chars, alphabet > 8, entropy ~5.1, ends in `=` padding: the
      // run up to the first `=` parses as a "key" only for an unbounded
      // assignment match. Masked before the carve-out, must stay masked.
      // (The literal is pieced together so no single source line carries
      // a secret-shaped token — adjacent literals concatenate in Dart.)
      const b64 =
          'ZmIoNyph'
          'ZDlQcUByWi'
          'VmbzhTZXQz'
          'djVyITA9'
          '=';
      final matches = layerEntropy('token $b64 end', _cfg);
      expect(matches, hasLength(1), reason: 'padded base64 must stay masked');
      expect(matches.single.kindLabel, highEntropyLabel);
    });

    test('a KEY=<random> assignment in tool output is still masked', () {
      // `printenv`/CI-log/config lines: an arbitrary key with a random
      // value (SESSION_KEY is NOT in the context layer's fixed anchor
      // list, so the entropy layer was — and stays — the only net for
      // this class). Pieced literal, same reason as the base64 test.
      const line =
          'SESSION_'
          'KEY='
          'xJ8f2kQz'
          '7Lp3vN5w'
          'R9tY2uM4'
          'bC6dE1';
      final matches = layerEntropy('out $line tail', _cfg);
      expect(matches, hasLength(1), reason: 'KEY=<random> must stay masked');
      expect(matches.single.kindLabel, highEntropyLabel);
    });
  });

  group('structured-identifier anchors (issue #1999)', () {
    test('uuid/hex shapes match as end-anchored regexes', () {
      expect(
        isStructuredIdentifier('01a05ea4-c7fe-7cbe-9e93-1575eed34d59'),
        isTrue,
      );
      expect(
        isStructuredIdentifier('a3f5b2c8d71e94f60218b7cd45e6a190f83b27d4'),
        isTrue,
      );
      expect(isStructuredIdentifier('deadbeef_cafef00d'), isTrue);
      expect(
        // The anchors must be real `$` end-anchors, not a literal `\$`
        // suffix requirement: a plain uuid classifies without any dollar.
        isStructuredIdentifier('01a05ea4-c7fe-7cbe-9e93-1575eed34d5X'),
        isFalse,
      );
    });
  });
}
