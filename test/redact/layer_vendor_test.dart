import 'package:flutter_agent_harness/src/redact/layer_prefix.dart';
import 'package:flutter_agent_harness/src/redact/layer_vendor.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

const _cfg = RedactionConfig();

String matched(String src, MatchRange m) => src.substring(m.start, m.end);

// Local alias so expectations read naturally without exposing internals.
typedef MatchRange = RedactionMatch;

void main() {
  group('layerVendor', () {
    test('GitHub ghp_ token', () {
      const ghp = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      const src = 'tok $ghp end';
      final matches = layerVendor(src, _cfg);
      expect(matches, hasLength(1));
      expect(matched(src, matches.single), ghp);
      expect(matches.single.kindLabel, 'GitHub Token');
      expect(matches.single.layer, RedactionLayer.vendor);
    });

    test('GitHub gho_ token', () {
      const gho = 'gho_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final matches = layerVendor('tok $gho end', _cfg);
      expect(matches.single.kindLabel, 'GitHub Token');
    });

    test('GitHub fine-grained github_pat_ token', () {
      final pat = 'github_pat_${'A1b2' * 15}a';
      final src = 'see $pat please';
      final matches = layerVendor(src, _cfg);
      expect(matched(src, matches.single), pat);
      expect(matches.single.kindLabel, 'GitHub Token');
    });

    test('AWS access key', () {
      const key = 'AKIAABCDEFGHIJKLMNOP';
      const src = 'aws $key ok';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'AWS Access Key');
      expect(matched(src, matches.single), key);
    });

    test('OpenAI key', () {
      final key = 'sk-${'a0B' * 7}a';
      final src = 'openai $key end';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'OpenAI Key');
      expect(matched(src, matches.single), key);
    });

    test('JWT with three base64url segments', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
          'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
      const src = 'auth $jwt done';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'JWT');
      expect(matched(src, matches.single), jwt);
    });

    test('GitLab token', () {
      final tok = 'glpat-${'a1B2' * 5}';
      final src = 'gitlab $tok end';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'GitLab Token');
      expect(matched(src, matches.single), tok);
    });

    test('Slack token', () {
      const tok = 'xoxb-123456789012-abcdef';
      const src = 'slack $tok end';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'Slack Token');
      expect(matched(src, matches.single), tok);
    });

    test('Google API key', () {
      final key = 'AIza${'Aa1' * 11}Ab';
      final src = 'gmaps $key end';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'Google API Key');
      expect(matched(src, matches.single), key);
    });

    test('npm token', () {
      final tok = 'npm_${'Aa1' * 12}';
      final src = 'npm $tok end';
      final matches = layerVendor(src, _cfg);
      expect(matches.single.kindLabel, 'npm Token');
      expect(matched(src, matches.single), tok);
    });

    test('multiple tokens in one text', () {
      const ghp = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      const aws = 'AKIAABCDEFGHIJKLMNOP';
      expect(layerVendor('$ghp and $aws', _cfg), hasLength(2));
    });

    test('near-miss shapes do not match', () {
      expect(layerVendor('short sk-123 and AKIA12', _cfg), isEmpty);
      expect(layerVendor('not a token ghp_123', _cfg), isEmpty);
      expect(layerVendor('plain words only', _cfg), isEmpty);
      expect(layerVendor('', _cfg), isEmpty);
    });
  });

  group('quickScreen', () {
    test('false for text without vendor prefixes', () {
      expect(quickScreen('nothing here, just prose'), isFalse);
      expect(quickScreen(''), isFalse);
    });

    test('true when a distinctive prefix is present', () {
      for (final probe in [
        'ghp_x',
        'gho_x',
        'github_pat_x',
        'sk-x',
        'AKIAx',
        'eyJx',
        'glpat-x',
        'xox-x',
        'AIzax',
        'npm_x',
      ]) {
        expect(quickScreen(probe), isTrue, reason: probe);
      }
    });
  });

  group('layerPrefix', () {
    test('flags the same spans as vendor when vendor is enabled', () {
      const ghp = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      const src = 'tok $ghp end';
      final fromVendor = layerVendor(src, _cfg);
      final fromPrefix = layerPrefix(src, _cfg);
      expect(fromPrefix, hasLength(1));
      expect(fromPrefix.single.start, fromVendor.single.start);
      expect(fromPrefix.single.end, fromVendor.single.end);
      expect(fromPrefix.single.kindLabel, fromVendor.single.kindLabel);
    });

    test('returns nothing on its own when vendor is disabled', () {
      const cfg = RedactionConfig(layerToggles: {RedactionLayer.vendor: false});
      const ghp = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      expect(layerPrefix('tok $ghp end', cfg), isEmpty);
    });
  });
}
