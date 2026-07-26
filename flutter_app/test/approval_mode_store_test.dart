// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/approval_mode_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentConfig _config() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'test-model',
  baseUrl: 'https://example.test',
  apiKey: 'test-key',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApprovalModeStore', () {
    test('missing file loads as null', () async {
      final env = MemoryExecutionEnv();
      expect(await ApprovalModeStore(env).load(), isNull);
    });

    test('corrupt file loads as null instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/approval_mode.json', 'not json {');
      expect(await ApprovalModeStore(env).load(), isNull);
    });

    test('unknown mode name loads as null', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/approval_mode.json',
        '{"version": 1, "mode": "anything-goes"}',
      );
      expect(await ApprovalModeStore(env).load(), isNull);
    });

    test('mode round-trips through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final store = ApprovalModeStore(env);
      await store.save(ApprovalMode.yolo);
      expect(await ApprovalModeStore(env).load(), ApprovalMode.yolo);

      await store.save(ApprovalMode.alwaysAsk);
      expect(await ApprovalModeStore(env).load(), ApprovalMode.alwaysAsk);
    });
  });

  group('AgentService approval persistence', () {
    test(
      'setApprovalMode persists; a re-created service restores yolo',
      () async {
        final env = MemoryExecutionEnv();
        final first = await AgentService.create(config: _config(), env: env);
        addTearDown(first.dispose);
        expect(first.approval.mode, ApprovalMode.write);

        first.setApprovalMode(ApprovalMode.yolo);
        // The write-through is fire-and-forget; give the env a moment.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final second = await AgentService.create(config: _config(), env: env);
        addTearDown(second.dispose);
        expect(second.approval.mode, ApprovalMode.yolo);
      },
    );

    test('a persisted mode seeds the service at creation', () async {
      final env = MemoryExecutionEnv();
      await ApprovalModeStore(env).save(ApprovalMode.alwaysAsk);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);
      expect(service.approval.mode, ApprovalMode.alwaysAsk);
    });

    test('clone() inherits the current mode, not a fresh disk read', () async {
      final env = MemoryExecutionEnv();
      // Disk says yolo (from an earlier run)...
      await ApprovalModeStore(env).save(ApprovalMode.yolo);
      final service = await AgentService.create(config: _config(), env: env);
      addTearDown(service.dispose);
      // ...but the user dialed this service down in the settings dialog.
      service.setApprovalMode(ApprovalMode.alwaysAsk);
      // Wipe the persisted value: a fresh read would give the default.
      await env.writeFile('${env.cwd}/approval_mode.json', '{}');

      final clone = service.clone();
      addTearDown(clone.dispose);
      expect(clone.approval.mode, ApprovalMode.alwaysAsk);
    });
  });
}
