import 'dart:convert';

import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:test/test.dart';

RedactionPipeline pipe([List<String> secrets = const []]) =>
    RedactionPipeline(registeredSecrets: secrets);

String pemBlockOfLines(int lines) {
  const body =
      'MIIqxdcABcDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwx0123456789+/';
  final parts = <String>['-----BEGIN PRIVATE KEY-----'];
  for (var i = 0; i < lines - 2; i++) {
    parts.add(body);
  }
  parts.add('-----END PRIVATE KEY-----');
  return parts.join('\n');
}

void main() {
  group('RedactionPipeline.scan', () {
  
  group('agent file-reading scenarios (entropy once shredded paths)', () {
    test('a package-lock read keeps integrity hashes and URLs, masks keys',
        () {
      const lockfile = '{\n'
          '  "packages": {\n'
          '    "esbuild": {\n'
          '      "version": "0.21.5",\n'
          '      "resolved": "https://registry.npmjs.org/esbuild/-/esbuild-0.21.5.tgz",\n'
          '      "integrity": "sha512-mg4aOJjqPBvUnLo0BWafbbTVBThScgeBAmBAJqDkxRYj0zOa1b2c3d4e5f6g7h8i9j0",\n'
          '      "dev": true\n'
          '    }\n'
          '  },\n'
          '  "jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
          'eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
          'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",\n'
          '  "apiKey": "sk-proj-9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8'
          'c7b6a5f4e3d2c1b0a9f8e7d6c"\n'
          '}\n';
      final out = pipe().redact(lockfile);
      expect(out, contains('sha512-mg4aOJjqPBvUnLo0BWafbbTVBThScgeBAmBAJqDk'));
      expect(out, contains('https://registry.npmjs.org/esbuild/-/esbuild'));
      expect(out, contains('[REDACTED:JWT]'));
      expect(out, contains('[REDACTED:Sensitive Value]'));
    });

    test('an ls/find listing keeps every path intact', () {
      const listing = '/Users/x/Library/Group Containers/group.dev.fa1.shared'
          '/fa/sessions/--Users-x-Library-App-dev.fa1.app--/messages'
          '/2026-09-01T23-24-12-542725_01a05ea4-c7fe-7cbe-9e93-1575eed34d59.json\n'
          '/Users/x/git/pkg/lib/src/redact/layer_entropy.dart\n'
          '/Users/x/git/pkg/flutter_app/test/golden/goldens/settings_hosted.png\n';
      final out = pipe().redact(listing);
      expect(out, contains('layer_entropy.dart'));
      expect(out, contains('settings_hosted.png'));
      expect(
        out,
        contains(
          '2026-09-01T23-24-12-542725_01a05ea4-c7fe-7cbe-9e93-1575eed34d59.json',
        ),
      );
      expect(out, isNot(contains('[REDACTED')));
    });
  });

  test('returns priority-ordered, non-overlapping matches', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = pipe();
      final matches = p.scan('pass: hunter2 then $token end');
      expect(matches.map((m) => m.layer), everyElement(RedactionLayer.vendor));
      for (final m in matches) {
        expect(m.kindLabel, isNotEmpty);
        expect(m.end, greaterThan(m.start));
      }
    });

    test('registered beats vendor on the same span', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = pipe([token]);
      final matches = p.scan('tok $token end');
      expect(matches, hasLength(1));
      expect(matches.single.layer, RedactionLayer.registered);
    });

    test('PEM body does not produce a second entropy match', () {
      final p = pipe();
      final matches = p.scan(pemBlockOfLines(30));
      expect(matches, hasLength(1));
      expect(matches.single.kindLabel, 'PEM PRIVATE KEY');
    });

    test('disabled pipeline yields nothing', () {
      const cfg = RedactionConfig(enabled: false);
      final p = RedactionPipeline(registeredSecrets: const [], config: cfg);
      expect(p.scan('password=hunter2 token ghp_x'), isEmpty);
    });

    test('empty text yields nothing', () {
      expect(pipe().scan(''), isEmpty);
    });
  });

  group('RedactionPipeline.redact', () {
    test('marker format [REDACTED:<kindLabel>]', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      expect(
        pipe().redact('tok $token end'),
        'tok [REDACTED:GitHub Token] end',
      );
    });

    test('context value next to a vendor token: vendor wins, key survives', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      expect(
        pipe().redact('password: $token done'),
        'password: [REDACTED:GitHub Token] done',
      );
    });

    test('slices are applied by concat, not global replace', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final out = pipe().redact('$token ... $token');
      expect(out, '[REDACTED:GitHub Token] ... [REDACTED:GitHub Token]');
    });

    test('idempotent: redact(redact(x)) == redact(x)', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      const composite =
          'pass: hunter2\npostgres://u:pw@h/db\n'
          'token $token\nsee id_rsa\n';
      final p = pipe(['topsecretvalue']);
      final once = p.redact(composite);
      expect(p.redact(once), once);
    });

    test('E3: registered secret containing "[REDACTED:" is still masked', () {
      const sneaky = 'sup3rsec[REDACTED:x]ret';
      final p = pipe([sneaky]);
      final out = p.redact('tok $sneaky end');
      expect(out, 'tok [REDACTED:Registered Secret] end');
      expect(p.redact(out), out);
    });

    test('JSON shape is preserved after redaction', () {
      final text = jsonEncode({'user': 'bob', 'password': 'hunter2', 'n': 1});
      final out = pipe().redact(text);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['user'], 'bob');
      expect(decoded['n'], 1);
      expect(decoded['password'], '[REDACTED:Sensitive Value]');
    });

    test('line count is preserved for a 30-line PEM block', () {
      final pem = pemBlockOfLines(30);
      final out = pipe().redact(pem);
      expect(out.split('\n'), hasLength(30));
      expect(out.startsWith('[REDACTED:PEM PRIVATE KEY]'), isTrue);
    });

    test('E4: CRLF line count is preserved', () {
      final body = List.filled(4, 'aB3xK9mQ7zR5tW8yU2vN4sD6fG1hJ0cV');
      final pem = [
        '-----BEGIN PRIVATE KEY-----',
        ...body,
        '-----END PRIVATE KEY-----',
      ].join('\r\n');
      final out = pipe().redact(pem);
      expect(out.split('\n'), hasLength(6));
      expect(out.contains('\r'), isFalse);
    });

    test('data URLs pass through verbatim', () {
      const dataUrl =
          'data:image/png;base64,qZ3mK8vB2nR7xW4cJ9fT5gL0dP1sH6yUqZ3mK8';
      final out = pipe().redact('img $dataUrl password=hunter2');
      expect(out.contains(dataUrl), isTrue);
      expect(out.contains('[REDACTED:Sensitive Value]'), isTrue);
    });

    test('E10: scan finds nothing inside a data URL', () {
      const dataUrl =
          'data:image/png;base64,qZ3mK8vB2nR7xW4cJ9fT5gL0dP1sH6yUqZ3mK8';
      expect(pipe().scan(dataUrl), isEmpty);
    });

    test('E1: git SHA and UUID survive by default', () {
      const text =
          'sha 86f7e437faa5a7fce15d1ddcb9eaeaea377667b8 and '
          'uuid 550e8400-e29b-41d4-a716-446655440000';
      expect(pipe().scan(text), isEmpty);
      expect(pipe().redact(text), text);
    });

    test('E1/E9: allowlist suppresses matches fully covered by it', () {
      const sha = '86f7e437faa5a7fce15d1ddcb9eaeaea377667b8';
      const uuid = '550e8400-e29b-41d4-a716-446655440000';
      final cfg = RedactionConfig(
        minEntropy: 3.0,
        allowlistRegexes: [RegExp(r'[0-9a-f]{40}'), RegExp(uuid)],
      );
      final p = RedactionPipeline(registeredSecrets: const [], config: cfg);
      final text = 'sha $sha uuid $uuid';
      expect(p.scan(text), isEmpty);
      expect(p.redact(text), text);
    });

    test('E9: allowlisted long token survives', () {
      const token = 'qZ3mK8vB2nR7xW4cJ9fT5gL0dP1sH6yU';
      final cfg = RedactionConfig(
        allowlistRegexes: [RegExp(RegExp.escape(token))],
      );
      final p = RedactionPipeline(registeredSecrets: const [], config: cfg);
      final text = 'tok $token end';
      expect(p.scan(text), isEmpty);
      expect(p.redact(text), text);
    });

    test('E8: pathHint of a credential file masks the whole dump', () {
      const dump = 'API_KEY=abc123\nDB_PASSWORD=hunter2\nTOKEN=zzzz\n';
      final p = pipe();
      final matches = p.scan(dump, pathHint: '.env');
      expect(matches, hasLength(1));
      expect(matches.single.kindLabel, 'Credential File');
      final out = p.redact(dump, pathHint: '.env');
      expect(out, '[REDACTED:Credential File]\n\n\n');
      // Idempotent: re-redacting the masked dump does not grow markers.
      expect(p.redact(out, pathHint: '.env'), out);
    });

    test('live config re-toggle via config setter', () {
      const token = 'ghp_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk1Ll2';
      final p = RedactionPipeline(
        registeredSecrets: const [],
        config: RedactionConfig(layerToggles: {RedactionLayer.vendor: false}),
      );
      final text = 'tok $token end';
      expect(
        p.scan(text).where((m) => m.layer == RedactionLayer.vendor),
        isEmpty,
      );
      p.config = const RedactionConfig();
      expect(p.redact(text), 'tok [REDACTED:GitHub Token] end');
    });

    test('registerSecret enforces the 8-char minimum (parity)', () {
      final p = pipe();
      p.registerSecret('short7d');
      p.registerSecret('longenough8');
      expect(p.scan('x short7d y'), isEmpty);
      expect(p.scan('x longenough8 y'), isNotEmpty);
    });

    test('unregisterSecret stops masking', () {
      final p = pipe(['topsecretvalue']);
      expect(
        p.redact('x topsecretvalue y'),
        'x [REDACTED:Registered Secret] y',
      );
      p.unregisterSecret('topsecretvalue');
      expect(p.redact('x topsecretvalue y'), 'x topsecretvalue y');
    });

    test('registeredSecrets getter reflects registrations', () {
      final p = pipe(['aaaaaaaa', 'bbbbbbbb']);
      p.registerSecret('cccccccc8');
      expect(p.registeredSecrets, ['aaaaaaaa', 'bbbbbbbb', 'cccccccc8']);
      p.unregisterSecret('aaaaaaaa');
      expect(p.registeredSecrets, ['bbbbbbbb', 'cccccccc8']);
    });

    test('same-start same-layer overlap keeps the longer span', () {
      final p = pipe(['abcd1234', 'abcd12345678']);
      final matches = p.scan('x abcd12345678 y');
      expect(matches, hasLength(1));
      expect(
        'x abcd12345678 y'.substring(matches.single.start, matches.single.end),
        'abcd12345678',
      );
      expect(matches.single.length, 12);
      expect(matches.single.toString(), contains('registered'));
    });

    test('empty text passes through', () {
      expect(pipe().redact(''), '');
    });
  });
}
