// End-to-end redaction integration tests (issue #24 AC5/AC6/AC7/AC8).
//
// A real [Agent] driven by a scripted fake provider and real [AgentTool]s,
// with the production wiring (`attachRedactionPipeline`) and a real
// `JsonlSessionRepo` over an in-memory file system. The session JSONL is
// asserted byte-level: no raw secret ever reaches the file.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A GitHub personal access token the vendor layer must catch.
const _ghp = 'ghp_AaBbCcDdEeFfGgHhJiKjLmMnNoPpQqRrSsTt';

/// A PEM private key block the PEM layer must catch.
const _pem = r'''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKjMzEf
YyjiWA4R4/M2bS1GB4t7NXp98C3SC6dVMvDuictGeurT8jNbvJZHtCSuYEvuNMoSj76
2l3A=
-----END PRIVATE KEY-----
''';

/// A credential file path blockMode must deny.
const _blockedPath = 'home/u/.ssh/id_rsa';

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// Fake [StreamFunction]: replays scripted turns, records every outgoing
/// context (what the provider would have seen).
class _FakeStream {
  _FakeStream(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

AgentTool _tool(
  String name,
  Future<ToolExecutionResult> Function(Map<String, dynamic>) execute,
) {
  return AgentTool(
    name: name,
    description: '$name tool',
    parameters: const {},
    execute: (args, cancelToken, onUpdate) => execute(args),
  );
}

/// Concatenates every stored session JSONL file (sessions live in
/// per-cwd subdirectories).
Future<String> _dumpSessionJsonl(MemoryExecutionEnv env) async {
  final buffer = StringBuffer();
  Future<void> walk(String dir) async {
    for (final entry in (await env.listDir(dir)).getOrThrow()) {
      if (entry.kind == FileKind.directory) {
        await walk(entry.path);
      } else if (entry.path.endsWith('.jsonl')) {
        buffer.write((await env.readTextFile(entry.path)).getOrThrow());
      }
    }
  }

  await walk('/sessions');
  return buffer.toString();
}

void main() {
  group('redaction e2e (issue #24)', () {
    test('AC5: tool result is masked in the provider context and in the '
        'session JSONL', () async {
      final fake = _FakeStream([
        _toolTurn([
          ToolCall(
            id: 'call-1',
            name: 'read',
            arguments: {'path': 'package-lock.json'},
          ),
        ]),
        _textTurn('done'),
      ]);
      final registry = ToolRegistry()
        ..register(
          _tool(
            'read',
            (_) async => ToolExecutionResult.text('apiKey=$_ghp\n$_pem'),
          ),
        );
      final agent = Agent(streamFunction: fake.call, toolRegistry: registry);
      final pipeline = RedactionPipeline(registeredSecrets: const []);
      attachRedactionPipeline(agent, pipeline);

      await agent.promptMessage(UserMessage.text('read the lockfile'));
      await agent.waitForIdle();

      // The provider saw exactly two calls: the tool turn and the follow-up.
      expect(fake.calls, 2);
      final toolResult = fake.contexts[1].messages
          .whereType<ToolResultMessage>()
          .single;
      final resultText = (toolResult.content.single as TextContent).text;
      expect(resultText, contains('[REDACTED:GitHub Token]'));
      expect(resultText, contains('[REDACTED:PEM PRIVATE KEY]'));
      expect(resultText.contains(_ghp), isFalse);
      expect(resultText.contains('[REDACTED:High Entropy String]'), isFalse);

      // The session JSONL — the persisted, shareable record — carries the
      // masked text, never the raw secret bytes.
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      for (final message in agent.state.messages) {
        await session.appendMessage(message);
      }
      final jsonl = await _dumpSessionJsonl(env);
      expect(jsonl.contains(_ghp), isFalse);
      expect(jsonl.contains('[REDACTED:High Entropy String]'), isFalse);
      expect(jsonl, contains('[REDACTED:GitHub Token]'));
    });

    test(
      'AC6: blockMode denies a credential-file read before execution',
      () async {
        var executed = false;
        final fake = _FakeStream([
          _toolTurn([
            ToolCall(
              id: 'call-1',
              name: 'read',
              arguments: {'path': _blockedPath},
            ),
          ]),
          _textTurn('done'),
        ]);
        final registry = ToolRegistry()
          ..register(
            _tool('read', (_) async {
              executed = true;
              return ToolExecutionResult.text('id_rsa contents');
            }),
          );
        final agent = Agent(streamFunction: fake.call, toolRegistry: registry);
        final pipeline = RedactionPipeline(
          registeredSecrets: const [],
          config: const RedactionConfig(blockMode: true),
        );
        attachRedactionPipeline(agent, pipeline);

        await agent.promptMessage(UserMessage.text('read my ssh key'));
        await agent.waitForIdle();

        // Blocked before the executor ran; the denial (not the file contents)
        // reaches the provider context, and the credential path itself never
        // survives into the result text.
        expect(executed, isFalse);
        final toolResult = fake.contexts[1].messages
            .whereType<ToolResultMessage>()
            .single;
        expect(toolResult.isError, isTrue);
        final text = (toolResult.content.single as TextContent).text;
        expect(text, contains('redact.blockMode'));
        expect(
          text,
          contains('[REDACTED:Credential File]'),
          reason: 'the denial masks the credential basename',
        );
        expect(text.contains('id_rsa contents'), isFalse);
        expect(text.contains(_blockedPath), isFalse);
      },
    );

    test(
      'AC7: a write-side tool result passes through byte-identical',
      () async {
        final fake = _FakeStream([
          _toolTurn([
            ToolCall(
              id: 'call-1',
              name: 'write',
              arguments: {'path': 'out.dart', 'content': _ghp},
            ),
          ]),
          _textTurn('done'),
        ]);
        final registry = ToolRegistry()
          ..register(
            _tool(
              'write',
              (_) async =>
                  ToolExecutionResult.text('wrote out.dart ($_ghp bytes)'),
            ),
          );
        final agent = Agent(streamFunction: fake.call, toolRegistry: registry);
        final pipeline = RedactionPipeline(registeredSecrets: const []);
        attachRedactionPipeline(agent, pipeline);

        await agent.promptMessage(UserMessage.text('write it'));
        await agent.waitForIdle();

        final toolResult = fake.contexts[1].messages
            .whereType<ToolResultMessage>()
            .single;
        final text = (toolResult.content.single as TextContent).text;
        // Model-generated code-shape strings survive untouched (AC7).
        expect(text, contains(_ghp));
        expect(pipeline.stats.byTool.values.fold<int>(0, (a, b) => a + b), 0);
      },
    );

    test('AC8: the pasted secret in the prompt is masked before the '
        'provider and the session see it', () async {
      final fake = _FakeStream([_textTurn('ok')]);
      final agent = Agent(
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      );
      final pipeline = RedactionPipeline(registeredSecrets: const []);
      attachRedactionPipeline(agent, pipeline);

      // The host (CLI/app) applies redactPrompt at prompt entry.
      final pasted = 'use this key: $_ghp';
      final masked = redactPrompt(pipeline, pasted);
      expect(masked.contains(_ghp), isFalse);
      await agent.promptMessage(UserMessage.text(masked));
      await agent.waitForIdle();

      final userMessage = fake.contexts[0].messages
          .whereType<UserMessage>()
          .single;
      final text = userMessage.content as String;
      expect(text.contains(_ghp), isFalse);
      expect(text, contains('[REDACTED:GitHub Token]'));

      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      for (final message in agent.state.messages) {
        await session.appendMessage(message);
      }
      final jsonl = await _dumpSessionJsonl(env);
      expect(jsonl.contains(_ghp), isFalse);
      expect(pipeline.stats.byTool['user_input'], 1);
    });
  });
}
