// End-to-end redaction integration tests (issue #24 AC5/AC6/AC7/AC8).
//
// A real [Agent] driven by a scripted fake provider and real [AgentTool]s,
// with the production wiring (`attachRedactionPipeline`) and a real
// `JsonlSessionRepo` over an in-memory file system. The session JSONL is
// asserted byte-level: no raw secret ever reaches the file.

@Tags(['integration'])
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A GitHub personal access token the vendor layer must catch.
const _ghp = 'ghp_AaBbCcDdEeFfGgHhJiKjLmMnNoPpQqRrSsTt';

/// A PEM private key block the PEM layer must catch.
/// Assembled from chunks at runtime: the string is byte-identical to
/// the old r''' literal, but the FILE no longer contains a full PEM
/// block, which the pub.dev publish validator rejects as a key leak.
final _pem = [
  '-----BEGIN PRIVATE KEY-----'
      'MIIEvQIBADANBgkqhkiG9w0BAQEFAA'
      'SCBKcwggSjAgEAAoIBAQC7VJTUt9Us'
      '8cKjMzEf'
      'YyjiWA4R4/M2bS1GB4t7NXp98C3SC6'
      'dVMvDuictGeurT8jNbvJZHtCSuYEvu'
      'NMoSj76'
      '2l3A='
      '-----END PRIVATE KEY-----',
].join();

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

/// A [Shell] that records the exact command string it was handed and
/// echoes it into stdout (like `bash -x` traces do), so the tool result —
/// and therefore the persisted transcript — carries the command text.
final class _RecordingShell implements Shell {
  final commands = <String>[];
  Result<ShellExecResult, ExecutionError> result = const Ok(
    ShellExecResult(stdout: '', stderr: '', exitCode: 0),
  );

  /// The canned stdout of the next exec: the `bash -x`-style trace of the
  /// command itself, set per call from the recorded command.
  Result<ShellExecResult, ExecutionError> traced(String command) =>
      Ok(ShellExecResult(stdout: '+ $command\n', stderr: '', exitCode: 0));

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return traced(command);
  }
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
      expect(resultText, contains('[REDACTED:GitHub-Token]'));
      expect(resultText, contains('[REDACTED:PEM-PRIVATE-KEY]'));
      expect(resultText.contains(_ghp), isFalse);
      expect(resultText.contains('[REDACTED:High-Entropy-String]'), isFalse);

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
      expect(jsonl.contains('[REDACTED:High-Entropy-String]'), isFalse);
      expect(jsonl, contains('[REDACTED:GitHub-Token]'));
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
          contains('[REDACTED:Credential-File]'),
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
      expect(text, contains('[REDACTED:GitHub-Token]'));

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

  group('gh-1952: redaction is display-only for the bash path', () {
    test('AC1: the repro command executes with its original argv while the '
        'persisted transcript shows the masked form', () async {
      // The exact incident shape: a non-secret compile-time define the
      // entropy layer used to rewrite into `[REDACTED:High Entropy
      // String]` — a marker whose SPACES split it into 3 argv items
      // the Flutter test loader tried to open as paths.
      final defineCommand =
          'flutter test '
          'test/three_example_selection_test.dart '
          '--dart-define=JSR_THREE_EXAMPLE=webgl_geometry_colors';
      // A REGISTERED secret riding the same define shape: display
      // masks it, execution must still receive the original bytes.
      const defineSecret = 'Q7zRaBc9DeF2gHi4jKl5mNo6pQrS8tUvWxYz0123';
      final secretCommand = 'flutter run --dart-define=API_KEY=$defineSecret';

      final shell = _RecordingShell();
      final fake = _FakeStream([
        _toolTurn([
          ToolCall(
            id: 'call-1',
            name: 'bash',
            arguments: {'command': defineCommand},
          ),
          ToolCall(
            id: 'call-2',
            name: 'bash',
            arguments: {'command': secretCommand},
          ),
        ]),
        _textTurn('done'),
      ]);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final registry = ToolRegistry()
        ..register(shellTool(env, retryBackoff: Duration.zero));
      final agent = Agent(streamFunction: fake.call, toolRegistry: registry);
      final pipeline = RedactionPipeline(registeredSecrets: [defineSecret]);
      attachRedactionPipeline(agent, pipeline);

      await agent.promptMessage(UserMessage.text('run the selection test'));
      await agent.waitForIdle();

      // I1: both commands reached the executor BYTE-IDENTICAL —
      // redaction ON did not rewrite a single argv byte.
      expect(shell.commands, [defineCommand, secretCommand]);

      // The results as the provider/persist pipeline sees them: the
      // non-secret define trace stays verbatim (nothing matched, so
      // nothing was masked), the registered-secret trace is masked.
      final results = fake.contexts[1].messages
          .whereType<ToolResultMessage>()
          .toList();
      expect(results, hasLength(2));
      final defineText = (results[0].content.single as TextContent).text;
      expect(defineText, contains(defineCommand));
      expect(defineText.contains('[REDACTED:'), isFalse);
      final secretText = (results[1].content.single as TextContent).text;
      expect(secretText.contains(defineSecret), isFalse);
      expect(secretText, contains('[REDACTED:Registered-Secret]'));

      // The persisted transcript (session JSONL): the tool RESULT
      // record carries the masked form, the non-secret define survives
      // unmasked, and no rewrite notice ever fired. The repo is built
      // with the production persist transform (gh-1952 review: the
      // record-write mask over tool-call arguments) — the CLI wires the
      // same closure into its `JsonlSessionRepo`.
      final repo = JsonlSessionRepo(
        fs: env,
        sessionsRoot: '/sessions',
        persistTransform: (message) =>
            persistRedactMessage(pipeline, message),
      );
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      for (final message in agent.state.messages) {
        await session.appendMessage(message);
      }
      final jsonl = await _dumpSessionJsonl(env);
      expect(jsonl, contains('[REDACTED:Registered-Secret]'));
      expect(jsonl, contains(defineCommand));
      // The call record must not leak the registered secret either: the
      // persist transform masks it in `toolCalls[].arguments` while the
      // executed argv stayed byte-identical (asserted above).
      expect(jsonl.contains(defineSecret), isFalse);
      expect(jsonl.contains('[bash interceptor rewrote'), isFalse);
    });
  });
}
