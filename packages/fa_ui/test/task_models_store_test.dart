// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<(TaskModelsStore, MemoryExecutionEnv)> loadFrom(String text) async {
    final env = MemoryExecutionEnv();
    if (text.isNotEmpty) {
      await env.writeFile('${env.cwd}/${TaskModelsStore.fileName}', text);
    }
    return (await TaskModelsStore.load(env), env);
  }

  group('TaskModelsStore._load', () {
    test('a missing file loads as empty', () async {
      final (store, _) = await loadFrom('');
      expect(store.configuredRoles, isEmpty);
      expect(store.overrideFor(TaskRole.smol), isNull);
    });

    test('an empty file loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/${TaskModelsStore.fileName}', '');
      final store = await TaskModelsStore.load(env);
      expect(store.configuredRoles, isEmpty);
    });

    test('a corrupt file loads as empty instead of crashing', () async {
      final (store, _) = await loadFrom('not json {');
      expect(store.configuredRoles, isEmpty);
    });

    test('a non-object document loads as empty', () async {
      final (store, _) = await loadFrom('[]');
      expect(store.configuredRoles, isEmpty);
    });

    test('a wrong schema version loads as empty', () async {
      final (store, _) = await loadFrom(
        '{"version": 99, "roles": {"smol": {"providerKind": "openai-completions",'
        ' "baseUrl": "https://x.example", "modelId": "m"}}}',
      );
      expect(store.configuredRoles, isEmpty);
    });

    test('a non-object roles member loads as empty', () async {
      final (store, _) = await loadFrom('{"version": 1, "roles": []}');
      expect(store.configuredRoles, isEmpty);
    });

    test('known roles load with their config fields', () async {
      final (store, _) = await loadFrom(
        '{"version": 1, "roles": {'
        '"smol": {"providerKind": "openai-completions",'
        ' "baseUrl": "https://fast.example/v1", "modelId": "fast-1"},'
        '"subagent": {"providerKind": "openai-completions",'
        ' "baseUrl": "https://delegate.example/v1", "modelId": "delegate-1",'
        ' "apiKeyName": "DELEGATE_KEY"}}}',
      );
      expect(
        store.configuredRoles,
        unorderedEquals([TaskRole.smol, TaskRole.subagent]),
      );

      final smol = store.overrideFor(TaskRole.smol);
      expect(smol, isNotNull);
      expect(smol!.providerKind, 'openai-completions');
      expect(smol.baseUrl, 'https://fast.example/v1');
      expect(smol.modelId, 'fast-1');
      expect(smol.apiKeyName, isNull);

      final subagent = store.overrideFor(TaskRole.subagent);
      expect(subagent, isNotNull);
      expect(subagent!.modelId, 'delegate-1');
      expect(subagent.apiKeyName, 'DELEGATE_KEY');
    });

    test('unknown roles and non-object values are ignored', () async {
      final (store, _) = await loadFrom(
        '{"version": 1, "roles": {'
        '"chief": {"providerKind": "p", "baseUrl": "b", "modelId": "m"},'
        '"smol": "not an object",'
        '"subagent": {"providerKind": "openai-completions",'
        ' "baseUrl": "https://delegate.example/v1", "modelId": "delegate-1"}}}',
      );
      expect(store.configuredRoles, [TaskRole.subagent]);
      expect(store.overrideFor('chief'), isNull);
      expect(store.overrideFor(TaskRole.smol), isNull);
    });
  });
}
