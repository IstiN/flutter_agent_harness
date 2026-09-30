// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1077 — app-side compaction integration tests (fakes, no network):
///
/// - **IT-1 (AC1)**: a session driven past the threshold compacts, and the
///   summarizer call rides the `smol` role resolved through the
///   store-backed roles chain (not the main connection).
/// - **IT-2 (AC2)**: with the summarizer call forced to fail everywhere,
///   the app shows the in-chat failure notice naming where to fix it
///   (string asserted), the session stays usable, and no fake summary is
///   invented — the failure-safe invariant (nothing appended, history
///   never lost) holds. E4: the next turn retries cleanly.
/// - **IT-3 (AC4)**: the loop's over-window guard hands the transcript to
///   the app's `overWindowRelief` — ONE synchronous relief attempt, the
///   relieved transcript retried, the turn completes instead of dying.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A text responder that records which MODEL ids it served.
StreamFunction _recordingText(List<String> seen, String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    seen.add(model.id);
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [TextContent(text: text)],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      ),
    );
    stream.end();
    return stream;
  };
}

/// Errors every summarization-shaped call (structured judge, structured
/// checkpoint, classic summary); answers ordinary turns with [text].
StreamFunction _failingSummarizer(List<String> seen, String text) {
  bool isSummarization(Context context) =>
      context.systemPrompt == summarizationSystemPrompt ||
      context.systemPrompt == hideJudgeSystemPrompt ||
      context.systemPrompt == structuredCheckpointPrompt;
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    seen.add(model.id);
    if (isSummarization(context)) {
      stream.push(
        DoneEvent(
          reason: StopReason.error,
          message: AssistantMessage(
            content: const [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.error,
            errorMessage: 'summary backend down',
            timestamp: DateTime.now(),
          ),
        ),
      );
    } else {
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: AssistantMessage(
            content: [TextContent(text: text)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ),
      );
    }
    stream.end();
    return stream;
  };
}

Agent _agent(
  StreamFunction stream, {
  int contextWindow = 512,
  String systemPrompt = '',
  List<AgentTool> tools = const [],
}) {
  return Agent(
    model: Model(
      id: 'main-model',
      name: 'main-model',
      api: 'anthropic-messages',
      provider: 'anthropic',
      baseUrl: 'https://main.invalid',
      contextWindow: contextWindow,
      maxTokens: 4096,
      input: const ['text'],
    ),
    systemPrompt: systemPrompt,
    streamFunction: stream,
    toolRegistry: ToolRegistry(tools),
  );
}

void main() {
  group('IT-1 — the smol chain drives compaction (AC1)', () {
    test('a session past the threshold compacts through the store-backed '
        'smol summarizer', () async {
      final smolSeen = <String>[];
      final env = MemoryExecutionEnv();
      final store = TaskModelsStore.inMemory({
        TaskRole.smol: TaskRoleConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://smol.invalid/v1',
          modelId: 'smol-model',
          apiKeyName: 'SMOL_KEY',
        ),
      });
      final service = AgentService(
        agent: _agent(_recordingText(<String>[], 'reply')),
        env: env,
        sessionsRoot: '/sessions',
        taskModelsStore: store,
        bootSecrets: const {'SMOL_KEY': 'smol-secret'},
        rolesStreamFactory: (kind, apiKey) {
          expect(kind, 'openai-completions');
          expect(apiKey, 'smol-secret');
          return _recordingText(smolSeen, 'smol summary');
        },
      );
      addTearDown(service.dispose);
      await service.initialize();

      // Three ~600-char turns cross the scaled threshold (window 512 →
      // trigger ≈ 384), like the main-only threshold test.
      await service.sendText('x' * 600);
      await service.waitForIdle();
      await service.sendText('y' * 600);
      await service.waitForIdle();
      expect(smolSeen, isEmpty, reason: 'under the threshold: no calls yet');

      await service.sendText('z' * 600);
      await service.waitForIdle();

      // A branch_summary-class record landed: the structured checkpoint
      // marker heads the rebuilt chat.
      expect(service.messages.first.content, contains('ckpt·'));
      expect(service.error, isNull);
      // The summarizer call rode the SMOL chain (the resolver-built
      // catalog model), not the main connection.
      expect(smolSeen, contains('smol-model'));
    });
  });

  group('IT-2 — failure surfacing (AC2, E3, E4)', () {
    test('a failing summarizer surfaces the in-chat notice and the session '
        'stays usable', () async {
      final seen = <String>[];
      final env = MemoryExecutionEnv();
      // Window 512 → reserve 128, keep 256, trigger 384. ~1200-char replies
      // (~300 tokens): after two turns the transcript is ~700 tokens — over
      // the trigger, under the window, and the NEWEST message alone exceeds
      // the kept region — so the local-trim valve has nothing droppable and
      // the failure must surface instead of silently no-oping.
      final service = AgentService(
        agent: _agent(
          _failingSummarizer(seen, 'r' * 1200),
          contextWindow: 512,
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      addTearDown(service.dispose);
      await service.initialize();

      await service.sendText('a' * 200);
      await service.waitForIdle();
      expect(service.error, isNull);
      expect(service.overWindowReliefCountForTest, 0,
          reason: 'the guard never fired — the turn fits the window');
      expect(
        service.messages.any((m) => m.role == 'system'),
        isFalse,
        reason: 'under the threshold: no compaction, no notice yet',
      );

      await service.sendText('b' * 200);
      await service.waitForIdle();

      // AC2: an in-chat notice names where to fix the summarizer.
      expect(
        service.messages.any(
          (m) =>
              m.role == 'system' &&
              m.content.contains('Settings → Task models → Quick model'),
        ),
        isTrue,
        reason: 'the failure notice must name the fix location',
      );
      // No silent run error, no invented summary, history intact.
      expect(service.error, isNull);
      final rendered = service.messages.map((m) => m.content).join('\n');
      expect(rendered, isNot(contains('compacted into the following summary')));
      expect(rendered, contains('b' * 200));
      expect(service.messages.where((m) => m.role == 'user'), hasLength(2));

      // E4: the next turn's request no longer fits the window — the loop's
      // guard hands it to the relief, the local trim succeeds there (the
      // newest message is tiny), and the session keeps working.
      await service.sendText('ping');
      await service.waitForIdle();
      expect(service.error, isNull);
      expect(service.overWindowReliefCountForTest, 1);
      expect(service.messages.last.content, 'r' * 1200);
    });
  });

  group('IT-3 — over-window relief (AC4)', () {
    test('a mid-run overflow triggers ONE relief attempt and the turn '
        'completes', () async {
      // Window 8192: an ~8500-token tool result balloons the transcript
      // mid-run → the loop's guard refuses request 2 → the relief runs one
      // synchronous compaction → the relieved transcript is retried.
      var streamCalls = 0;
      AssistantMessageEventStream hugeToolThenText(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        streamCalls++;
        final stream = AssistantMessageEventStream();
        if (streamCalls == 1) {
          stream.push(
            DoneEvent(
              reason: StopReason.toolUse,
              message: AssistantMessage(
                content: [
                  ToolCall(
                    id: 'tc-1',
                    name: 'echo',
                    arguments: const {'x': 'go'},
                  ),
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.toolUse,
                timestamp: DateTime.now(),
              ),
            ),
          );
        } else {
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: [TextContent(text: 'continued')],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.now(),
              ),
            ),
          );
        }
        stream.end();
        return stream;
      }

      final echoTool = AgentTool(
        name: 'echo',
        description: 'echo',
        parameters: const {
          'type': 'object',
          'properties': {
            'x': {'type': 'string'},
          },
          'required': ['x'],
        },
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('y' * 34000),
      );
      final env = MemoryExecutionEnv();
      final service = AgentService(
        agent: _agent(
          hugeToolThenText,
          contextWindow: 8192,
          tools: [echoTool],
        ),
        env: env,
        sessionsRoot: '/sessions',
      );
      // This test exercises the over-window guard, not approval: unattended
      // run (write mode would deny the unknown tool with a 37-char note and
      // the ballooned result would never exist).
      service.approval.mode = ApprovalMode.yolo;
      addTearDown(service.dispose);
      await service.initialize();

      await service.sendText('go');
      await service.waitForIdle();

      // AC4: exactly ONE synchronous relief attempt, the turn retried and
      // completed — no dead turn, no loop.
      expect(service.overWindowReliefCountForTest, 1);
      expect(service.messages.last.content, 'continued');
      expect(service.error, isNull);
      expect(
        service.messages.map((m) => m.content).join('\n'),
        isNot(contains('y' * 500)),
        reason: 'the relief compacted the ballooned transcript',
      );
      expect(
        service.messages.where((m) => m.content == 'continued').length,
        1,
        reason: 'no trim→continue loop',
      );
      expect(streamCalls, greaterThanOrEqualTo(2));
    });
  });
}
