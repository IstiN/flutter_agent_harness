// gh-1680 follow-up (PR #1695 coverage): the CLI-side message-cap heal
// glue executed IN-PROCESS — `_relieveMessageCap` (the host-relief
// extension), `_persistModelCaps` (AC2 boot-load), `_CliMessageCapPolicy`
// and the cap gate. These lines only run inside an `AgentCli` whose agent
// loop heals a classified cap refusal; the PTY/AOT legs execute them in a
// subprocess the coverage harness cannot see, so the in-process drive
// here is the measurement that counts.
//
// Reactive leg: a first request answered with a `array length N exceeds
// limit M` refusal → the CLI learns cap 2048, persists it under
// `<homeDir>/.fah/model_caps.json`, runs one relief pass, coalesces the
// armed payload and retries ONCE into a completing answer.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 200000,
  maxTokens: 4096,
);

const _incident = '400 messages: array length 2049 exceeds limit 2048';
const _checkpointReply =
    'CAP CHECKPOINT: earlier turns folded into this summary.';

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
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

List<AssistantMessageEvent> _capRefusalTurn(String error) {
  final msg = _assistant(stopReason: StopReason.error, errorMessage: error);
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

/// Judge/checkpoint-aware fake: the structured compaction passes get
/// deterministic answers (hide nothing, canned summary); REAL agent turns
/// pop [answers] in order.
final class _CapAwareStream {
  final answers = <List<AssistantMessageEvent>>[];
  final contexts = <Context>[];
  var _answered = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final prompt = [
      for (final m in context.messages)
        switch (m) {
          UserMessage() => messageText(m),
          AssistantMessage() =>
            m.content.whereType<TextContent>().map((b) => b.text).join(),
          _ => '',
        },
    ].join('\n');
    final List<AssistantMessageEvent> turn;
    if (prompt.contains('context-hygiene judge')) {
      turn = _textTurn('[]');
    } else if (prompt.contains('Write a checkpoint')) {
      turn = _textTurn(_checkpointReply);
    } else {
      turn = answers[_answered++ % answers.length];
    }
    final stream = AssistantMessageEventStream();
    for (final event in turn) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }

  /// The agent-turn requests (the compaction judge/checkpoint calls are
  /// filtered out by their own system prompts).
  Iterable<Context> get turnRequests => contexts.where(
    (context) => (context.systemPrompt ?? '').startsWith('You are Fa'),
  );
}

Future<void> waitUntil(
  bool Function() condition,
  String Function() describe,
) async {
  for (var i = 0; i < 5000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${describe()}');
}

void main() {
  late Directory tempHome;
  late FakeCliIO io;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('fa_cap_cli_home_');
    io = FakeCliIO();
  });
  tearDown(() {
    io.close();
    tempHome.deleteSync(recursive: true);
  });

  File capsFile() => File('${tempHome.path}/.fah/model_caps.json');

  AgentCli cli(MemoryExecutionEnv env, _CapAwareStream stream) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      homeDir: tempHome.path,
    ),
    io: io,
    streamFunction: stream.call,
  );

  test(
    'a cap refusal heals: learn, persist, relieve, coalesce, retry',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      // Suppress session-start memory maintenance (suite pattern).
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final stream = _CapAwareStream()
        ..answers.addAll([
          _capRefusalTurn(_incident),
          _textTurn('healed reply'),
        ]);
      final agent = cli(env, stream);

      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () => stream.turnRequests.length >= 2 && !agent.isBusy,
        () =>
            'heal: turns=${stream.turnRequests.length} '
            'calls=${stream.contexts.length} out=${io.out}',
      );
      io.sendLine('/exit');
      await run;

      // The retry completed the turn.
      expect(io.out.toString(), contains('healed reply'));

      // The parsed cap persisted for the next boot (AC2) — the CLI-side
      // persistence glue, not just the in-memory loop store.
      expect(capsFile().existsSync(), isTrue, reason: io.out.toString());
      final persisted =
          jsonDecode(capsFile().readAsStringSync()) as Map<String, dynamic>;
      expect(
        persisted.values
            .whereType<Map>()
            .map((r) => r['maxMessages'])
            .whereType<int>(),
        contains(2048),
      );
    },
  );
}
