// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentService.mergeSecrets', () {
    test('dotenv first; explicitly saved keys override on conflict', () {
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-saved',
        'GITHUB_TOKEN': 'ghp_saved',
      });
      final merged = AgentService.mergeSecrets({
        'OPENROUTER_API_KEY': 'sk-dotenv',
        'DOTENV_ONLY': 'x',
      }, store);

      // The explicit user save wins over the dev .env on conflict.
      expect(merged['OPENROUTER_API_KEY'], 'sk-saved');
      // Dotenv-only entries survive; saved-only entries are added.
      expect(merged['DOTENV_ONLY'], 'x');
      expect(merged['GITHUB_TOKEN'], 'ghp_saved');
    });

    test('every merged name reaches the redactor (system prompt list)', () {
      final store = SessionKeysStore.inMemory({'GITHUB_TOKEN': 'ghp_saved'});
      final merged = AgentService.mergeSecrets({
        'DOTENV_ONLY': 'dotenv-x',
      }, store);

      final redactor = SecretRedactor.fromSecrets(merged);
      expect(redactor.names, containsAll(['DOTENV_ONLY', 'GITHUB_TOKEN']));
      // Values are redacted, names only are advertised.
      expect(
        redactor.redact('token is ghp_saved'),
        isNot(contains('ghp_saved')),
      );
    });

    test('null store passes the dotenv map through', () {
      final merged = AgentService.mergeSecrets({'A': '1'}, null);
      expect(merged, {'A': '1'});
    });
  });
}
