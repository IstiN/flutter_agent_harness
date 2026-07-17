import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_example/secrets_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // dart:io file access: host-only (same pattern as git_smart_http_test).
  if (kIsWeb) return;

  group('parseDotEnv', () {
    test('parses NAME=value lines, comments, export prefix, and quotes', () {
      final secrets = parseDotEnv(
        '# a comment\n'
        '\n'
        'OPENROUTER_API_KEY=sk-or-123\n'
        'export GITHUB_TOKEN=ghp_abc\n'
        'QUOTED="with spaces"\n'
        "SINGLE='single quotes'\n"
        'NO_EQUALS_LINE\n'
        '=empty-name\n'
        'EMPTY=\n',
      );
      expect(secrets, {
        'OPENROUTER_API_KEY': 'sk-or-123',
        'GITHUB_TOKEN': 'ghp_abc',
        'QUOTED': 'with spaces',
        'SINGLE': 'single quotes',
        'EMPTY': '',
      });
    });
  });

  group('DotEnvSecretsStore', () {
    test('reads secrets from the .env file and merges the overlay', () async {
      final dir = await Directory.systemTemp.createTemp('fah_secrets_test');
      try {
        await File(
          '${dir.path}/.env',
        ).writeAsString('FILE_KEY=file-value-123\nOVERRIDE=file\n');
        final store = DotEnvSecretsStore('${dir.path}/.env');
        store.set('OVERLAY_KEY', 'overlay-value-456');
        store.set('OVERRIDE', 'overlay');
        expect(await store.readAll(), {
          'FILE_KEY': 'file-value-123',
          'OVERRIDE': 'overlay',
          'OVERLAY_KEY': 'overlay-value-456',
        });
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing .env file yields only the overlay', () async {
      final store = DotEnvSecretsStore('/nonexistent/.env')..set('A', 'b');
      expect(await store.readAll(), {'A': 'b'});
    });
  });
}
