// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AC10 (issue #29): a scripted IN-APP turn that configures a setting via
/// the agent `config` tool — no shell, no `fa` process. The service is
/// built the way the app builds it (`AgentService.create` over a real
/// config), the provider is a script, and the scripted first response is
/// a `config` tool call. The turn must actually change the setting on the
/// host's project config.
library;

import 'dart:async';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/approval_mode_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Call 1 streams a `config` tool call; call 2 confirms in text.
StreamFunction _configSetThenText(String key, String value, String finalText) {
  var callCount = 0;
  return (model, context, {cancelToken}) {
    callCount++;
    final stream = AssistantMessageEventStream();
    final message = callCount == 1
        ? AssistantMessage(
            content: [
              ToolCall(
                id: 'tc-config-1',
                name: 'config',
                arguments: {'op': 'set', 'key': key, 'value': value},
              ),
            ],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.now(),
          )
        : AssistantMessage(
            content: [TextContent(text: finalText)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          );
    stream.push(DoneEvent(reason: message.stopReason!, message: message));
    stream.end();
    return stream;
  };
}

void main() {
  test(
    'an in-app turn reconfigures fa via the config tool (no shell)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/sandbox');
      // The app's own approval persistence, seeded to yolo so the scripted
      // turn's write-tier config call is auto-approved (no human present).
      await ApprovalModeStore(env).save(ApprovalMode.yolo);
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: env,
        streamFunction: _configSetThenText(
          'memory.projectPath',
          './memory',
          'Memory now points at ./memory.',
        ),
      );
      addTearDown(service.dispose);
      await service.initialize();

      await service.sendText('point project memory at ./memory');
      await service.waitForIdle();

      // The turn ran: tool call, then the confirmation.
      final roles = service.messages.map((m) => m.role).toList();
      expect(roles, contains('tool'));
      expect(service.messages.last.content, contains('./memory'));

      for (final m in service.messages) {
        // ignore: avoid_print
        print('MSG ' + m.role + ': ' + m.content);
      }

      // The setting ACTUALLY changed on the host config — the whole point
      // of self-configuration (the tool's write, not a scripted echo).
      final read = await env.readTextFile('/sandbox/.fah/config.yaml');
      final config = switch (read) {
        Ok(:final value) => value,
        Err(:final error) => fail('config file unread: $error'),
      };
      expect(config, contains('projectPath: ./memory'));

      // The in-app config tool also answers get against the same file.
      final configTool = service.toolsForTest
          .where((tool) => tool.name == 'config')
          .firstOrNull;
      expect(configTool, isNotNull, reason: 'config tool not registered');
    },
  );
}
