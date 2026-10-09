// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1444 AC4 review round: the sandbox `env` presence roster must carry
/// the ADVERTISED secret names — the well-known key names the app's Keys
/// section always lists even when unset — so `NAME: ABSENT` can render for
/// a not-yet-granted name, and a mid-session delete in the Keys section
/// (the production revocation path) flips the live value to ABSENT while
/// the name stays visible (E3).
library;

import 'dart:io';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _noStream(Model _) {
  final stream = AssistantMessageEventStream();
  stream.end();
  return stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late Directory project;

  setUp(() {
    home = Directory.systemTemp.createTempSync('fah-secret-roster-home');
    project = Directory.systemTemp.createTempSync('fah-secret-roster-proj');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  Future<AgentService> buildService(SessionKeysStore sessionKeys) {
    return AgentService.create(
      config: AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'test-model',
        baseUrl: 'https://example.test',
        apiKey: 'sk-test-1234567890',
      ),
      env: MemoryExecutionEnv(cwd: project.path),
      streamFunction: _noStream,
      sessionKeys: sessionKeys,
      configHomeDir: home.path,
      watchExternalSessions: false,
    );
  }

  group('the presence roster is the advertised name list (AC4)', () {
    test('well-known key names render ABSENT before any grant', () async {
      // Nothing granted anywhere: the roster still announces the names the
      // app always advertises, so `env` can prove absence.
      final service = await buildService(SessionKeysStore.inMemory());
      addTearDown(service.dispose);

      final env = service.secretsEnvForTest!;
      expect(env.secretsSnapshot(), isEmpty);
      expect(env.secretNames, containsAll(knownKeyNames));
    });

    test('granted names stay PRESENT in the roster', () async {
      final service = await buildService(
        SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-or-v1-0123456789',
        }),
      );
      addTearDown(service.dispose);

      final env = service.secretsEnvForTest!;
      expect(env.secretsSnapshot()['OPENROUTER_API_KEY'], isNotNull);
      expect(env.secretNames, containsAll(knownKeyNames));
    });
  });

  group('the Keys section is the production revocation path (E3)', () {
    test('a mid-session delete flips the value to ABSENT, name stays',
        () async {
      final keys = SessionKeysStore.inMemory({
        'GITHUB_TOKEN': 'ghp_0123456789abcdef',
      });
      final service = await buildService(keys);
      addTearDown(service.dispose);

      final env = service.secretsEnvForTest!;
      expect(env.secretsSnapshot()['GITHUB_TOKEN'], 'ghp_0123456789abcdef');

      // The settings Keys section delete: the store notifies, the env
      // revokes the value and keeps the name on the roster.
      await keys.delete('GITHUB_TOKEN');
      expect(env.secretsSnapshot().containsKey('GITHUB_TOKEN'), isFalse);
      expect(env.secretNames, contains('GITHUB_TOKEN'));
    });

    test('a re-saved key becomes PRESENT again', () async {
      final keys = SessionKeysStore.inMemory({
        'GITHUB_TOKEN': 'ghp_0123456789abcdef',
      });
      final service = await buildService(keys);
      addTearDown(service.dispose);

      final env = service.secretsEnvForTest!;
      await keys.delete('GITHUB_TOKEN');
      expect(env.secretsSnapshot().containsKey('GITHUB_TOKEN'), isFalse);

      await keys.set('GITHUB_TOKEN', 'ghp_fedcba9876543210');
      expect(env.secretsSnapshot()['GITHUB_TOKEN'], 'ghp_fedcba9876543210');
      expect(env.secretNames, contains('GITHUB_TOKEN'));
    });

    test('a dotenv-only secret survives a store edit', () async {
      // The store is NOT the only boot source: a dotenv entry must never
      // be revoked because the store does not list it.
      final keys = SessionKeysStore.inMemory({
        'GITHUB_TOKEN': 'ghp_0123456789abcdef',
      });
      final service = await buildService(keys);
      addTearDown(service.dispose);

      final env = service.secretsEnvForTest;
      // Dotenv simulation: inject a store-foreign name the way the .env
      // loader's boot map did.
      env!.addSecrets({'DOTENV_ONLY_VAR': 'dotenv-value-12345'});
      await keys.set('OPENROUTER_API_KEY', 'sk-or-v1-0123456789');

      expect(env.secretsSnapshot()['DOTENV_ONLY_VAR'], 'dotenv-value-12345');
      expect(env.secretsSnapshot()['OPENROUTER_API_KEY'],
          'sk-or-v1-0123456789');
    });
  });
}
