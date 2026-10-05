// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.
//
/// AC7 chat mini-test body (issue #1156): a chat agent loop on top of the
/// REAL platform sandbox shell, driven by the scripted OpenAI-compatible
/// [MockLlmServer].
///
/// Proves the full chat path — model -> tool call -> sandbox shell -> tool
/// result -> next model turn — without any network. The probes are the same
/// shell behaviors the golden probe suite pins (pipeline, stderr fidelity,
/// builtin versions), exercised through `AgentService` exactly like a user
/// chat would.
///
/// Owned by the simulator lane
/// (`integration_test/sandbox_agent_chat_test.dart`, WASI env via
/// `createPlatformEnv`); there is deliberately no host entry — the app
/// service stack does not run under flutter_tester.
library;

import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs the chat mini-test against `createPlatformEnv()`.
///
/// Starts a [MockLlmServer] unless [llm] is passed (the caller then owns
/// stopping it); the self-started one is stopped via `addTearDown`.
/// [screenshot] captures a named screenshot when the binding supports it.
Future<void> sandboxAgentChatProbe(
  WidgetTester tester, {
  MockLlmServer? llm,
  Future<void> Function(String name)? screenshot,
}) async {
  final resolvedEnv = await createPlatformEnv();
  final server = llm ?? await MockLlmServer.start();
  addTearDown(server.stop);

  // Three sandbox probes, then the model quotes the last tool result.
  server
    ..enqueueToolCall(
      'bash',
      '{"command": "echo chat-probe | sed \'s/chat/agent/\'"}',
    )
    ..enqueueToolCall('bash', '{"command": "echo err-line >&2; echo ok-line"}')
    ..enqueueToolCall('bash', '{"command": "jq --version"}')
    ..enqueueToolResultEcho();

  final agent = Agent(
    model: Model(
      id: 'mock-model',
      api: 'openai-completions',
      provider: 'mock',
      baseUrl: server.baseUrl,
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: (model, context, {CancelToken? cancelToken}) =>
        streamOpenAICompletions(
          model,
          context,
          OpenAICompletionsOptions(cancelToken: cancelToken, apiKey: 'mock'),
        ),
    toolRegistry: ToolRegistry(builtinTools(resolvedEnv)),
  );

  final service = AgentService(
    agent: agent,
    env: resolvedEnv,
    sessionsRoot: '${resolvedEnv.cwd}/sessions',
  );
  await service.initialize();

  final manager = FlutterSessionManager(
    env: resolvedEnv,
    sessionsRoot: '${resolvedEnv.cwd}/sessions',
  )..addSession('sandbox-chat-probe', service);
  await tester.pumpWidget(MaterialApp(home: ChatScreen(manager: manager)));
  await tester.pumpAndSettle();

  await service.sendText('run the sandbox probes');
  await service.waitForIdle();
  await tester.pumpAndSettle(const Duration(seconds: 2));

  // Pipeline through the real shell (WASI on the simulator lane).
  expect(
    service.messages.any(
      (m) => m.role == 'tool' && m.content.contains('agent-probe'),
    ),
    isTrue,
    reason: 'sed pipeline should have produced "agent-probe"',
  );
  // Stdout and stderr fidelity on the real loop.
  expect(
    service.messages.any(
      (m) => m.role == 'tool' && m.content.contains('ok-line'),
    ),
    isTrue,
    reason: 'stdout must reach the tool result',
  );
  expect(
    service.messages.any(
      (m) => m.role == 'tool' && m.content.contains('err-line'),
    ),
    isTrue,
    reason: 'stderr must reach the tool result',
  );
  // Built-in version pin (probe row 6 behavior, through the agent loop).
  expect(
    service.messages.any(
      (m) => m.role == 'tool' && m.content.contains('jq-1.7.1'),
    ),
    isTrue,
    reason: 'jq --version should answer like real jq',
  );

  // The model's final turn quoted the last tool result: the tool result
  // genuinely flowed back through the chat loop.
  final finalText = service.messages
      .lastWhere((m) => m.role == 'assistant')
      .content;
  expect(finalText, contains('jq'));

  await screenshot?.call('sandbox_agent_chat_probe');
}
