import 'package:flutter_agent_harness/src/redact/layer_path.dart';
import 'package:flutter_agent_harness/src/redact/redaction_types.dart';
import 'package:test/test.dart';

void main() {
  group('isCredentialPath', () {
    test('credential basenames', () {
      for (final p in [
        '.env',
        '/srv/app/.env',
        '.env.production',
        '/home/u/.ssh/id_rsa',
        'keys/id_ed25519',
        '.npmrc',
        '/root/.npmrc',
        '.netrc',
        '~/.aws/credentials',
        'config/.aws/credentials',
        '/home/u/.ssh/config',
        '/root/.docker/config.json',
        'server.pem',
        'C:\\Users\\x\\.ssh\\id_rsa',
      ]) {
        expect(isCredentialPath(p), isTrue, reason: p);
      }
    });

    test('ordinary files are not credential paths', () {
      for (final p in [
        'src/main.dart',
        'pubspec.yaml',
        'config.json',
        '.github/workflows/ci.yml',
        'readme.md',
        '',
      ]) {
        expect(isCredentialPath(p), isFalse, reason: p);
      }
    });
  });

  group('layerPath', () {
    test('pathHint of a credential file masks the whole text', () {
      const text = 'API_KEY=abc\nDB_PASSWORD=hunter2\n';
      final matches = layerPath(
        text,
        const RedactionConfig(),
        pathHint: '/srv/app/.env',
      );
      expect(matches, hasLength(1));
      expect(matches.single.start, 0);
      expect(matches.single.end, text.length);
      expect(matches.single.layer, RedactionLayer.path);
      expect(matches.single.kindLabel, credentialFileLabel);
    });

    test('pathHint of an ordinary file yields only inline tokens', () {
      const text = 'see ~/.ssh/id_rsa for keys';
      final matches = layerPath(
        text,
        const RedactionConfig(),
        pathHint: 'src/main.dart',
      );
      expect(matches, hasLength(1));
      expect(
        text.substring(matches.single.start, matches.single.end),
        'id_rsa',
      );
    });

    test('inline path tokens are masked (the token itself)', () {
      const text = 'cat ~/.ssh/id_rsa and /home/u/.env';
      final matches = layerPath(text, const RedactionConfig());
      expect(matches, isNotEmpty);
      final first = text.substring(matches.first.start, matches.first.end);
      expect(first, contains('id_rsa'));
      for (final m in matches) {
        expect(m.layer, RedactionLayer.path);
        expect(m.kindLabel, credentialFileLabel);
      }
    });

    test('inline credentials dirs and pem tokens', () {
      const text = 'check ~/.aws/credentials ~/.ssh/config';
      final matches = layerPath(text, const RedactionConfig());
      expect(matches.length, 2);
    });

    test('process.env is not a credential path (false-positive guard)', () {
      expect(layerPath('read process.env.FOO', const RedactionConfig()), isEmpty);
      expect(layerPath('the environment is fine', const RedactionConfig()), isEmpty);
    });

    test('a bare .env filename stays visible (no location info)', () {
      // Over-redaction regression: `- .env` in a pubspec asset list was
      // masked as a credential file, destroying ordinary config listings.
      // A bare well-known name reveals no secret location; paths do.
      expect(layerPath('- .env', const RedactionConfig()), isEmpty);
      expect(layerPath('load .env now', const RedactionConfig()), isEmpty);
    });

    test('directory-qualified .env paths are still masked', () {
      const text = 'cat project/.env ~/app/.env and ./.env';
      final matches = layerPath(text, const RedactionConfig());
      final masked = matches.map((m) => text.substring(m.start, m.end)).toSet();
      expect(masked, contains('project/.env'));
      expect(masked, contains('~/app/.env'));
      expect(masked, contains('./.env'));
    });

    test('process.env is not a credential path (false-positive guard)', () {
      expect(
        layerPath('read process.env.FOO', const RedactionConfig()),
        isEmpty,
      );
      expect(
        layerPath('the environment is fine', const RedactionConfig()),
        isEmpty,
      );
    });

    test('plain text yields nothing', () {
      expect(
        layerPath('no paths here at all', const RedactionConfig()),
        isEmpty,
      );
    });

    test('empty text yields nothing', () {
      expect(layerPath('', const RedactionConfig()), isEmpty);
    });
  });
}
