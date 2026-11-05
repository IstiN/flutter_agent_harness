// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2059 — extension-host compaction parity tests (pure Dart, VM):
/// the [ExtensionCompactionRunner] is the compaction brain behind the
/// web-only `agent_host.dart`, and everything the issue's ACs pin lives
/// here:
///
/// - AC1: mid-turn over-window → exactly ONE relief pass, retried
///   request under-window (the loop's guard contract, issue #387).
/// - AC2 (SW half): manual `/compact` runs a pass, emits the before/after
///   receipt notice, never touches the transcript with a user message.
/// - AC3: the under-window invariant over generated transcripts —
///   under the compaction trigger OR a visible notice, newest-message-
///   bigger-than-budget included.
/// - AC4: every pass logs ≥1 SW line; failures add ≥1 notice.
/// - AC5: a still-over pass re-fires exactly once, then the exhaustion
///   notice — no infinite loop.
/// - AC6: the incident replay fixture (30 turns of ~60k-char tool
///   results, effective window 128000) recovers to under-window.
/// - AC8: a cancelled relief/manual pass surfaces aborted/interrupted —
///   never a failed-pass notice.
/// - AC10 (grep half): no hand-rolled compaction constants in the host.
/// - AC11: the SW log alone answers "did a pass run, what did it drop,
///   why did it fail".
/// - the slash dispatch contract ([parseSlashInput]).
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/compaction/compaction.dart';
import 'package:flutter_agent_harness/src/compaction/token_estimation.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../src/host_compaction.dart';

final class _Rig {
  _Rig(this.session, this.agent, this.runner, this.logs, this.notices);

  final Session session;
  final Agent agent;
  final ExtensionCompactionRunner runner;
  final List<String> logs;
  final List<String> notices;

  int get requestTokens => runner.requestTokens;
}

bool _isSummarization(Context context) =>
    context.systemPrompt == summarizationSystemPrompt ||
    context.systemPrompt == hideJudgeSystemPrompt ||
    context.systemPrompt == structuredCheckpointPrompt;

AssistantMessage _assistant(Model model, String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

/// Turns answer [turnText] (repeated); every summarization-shaped call
/// answers [summary]. Both carry Usage.zero: the estimate stays
/// heuristic (zero usage never anchors — the same contract the relay
/// `usage=0` responses ride, gh-2059 border case).
StreamFunction textStream(String turnText, {String summary = 'summary'}) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: _assistant(
          model,
          _isSummarization(context) ? summary : turnText,
        ),
      ),
    );
    stream.end();
    return stream;
  };
}

/// First turn emits [call] (StopReason.toolUse), later turns answer
/// [tail]; summarization-shaped calls answer [summary].
StreamFunction _toolCallStream(
  ToolCall call,
  String tail, {
  String summary = 'summary',
}) {
  var turns = 0;
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    if (_isSummarization(context)) {
      stream.push(
        DoneEvent(reason: StopReason.stop, message: _assistant(model, summary)),
      );
    } else {
      turns++;
      final isCall = turns == 1;
      stream.push(
        DoneEvent(
          reason: isCall ? StopReason.toolUse : StopReason.stop,
          message: AssistantMessage(
            content: isCall ? [call] : [TextContent(text: tail)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: isCall ? StopReason.toolUse : StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ),
      );
    }
    stream.end();
    return stream;
  };
}

/// Every summarization-shaped call fails with [message]; ordinary turns
/// answer [turnText].
StreamFunction _failingSummarizerStream(String message, String turnText) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    if (_isSummarization(context)) {
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
            errorMessage: message,
            timestamp: DateTime.now(),
          ),
        ),
      );
    } else {
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: _assistant(model, turnText),
        ),
      );
    }
    stream.end();
    return stream;
  };
}

/// First summarization-shaped call cancels [source] then errors with
/// [message]; ordinary turns answer [turnText] — the deterministic
/// "user abort mid-pass" script (AC8).
StreamFunction _cancelOnSummarize(
  CancelTokenSource source,
  String message,
  String turnText,
) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    if (_isSummarization(context)) {
      source.cancel('user cancel');
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
            errorMessage: message,
            timestamp: DateTime.now(),
          ),
        ),
      );
    } else {
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: _assistant(model, turnText),
        ),
      );
    }
    stream.end();
    return stream;
  };
}

Future<_Rig> _rig(
  StreamFunction stream, {
  int contextWindow = 512,
  int? contextWindowCap,
  List<AgentTool> tools = const [],
  List<Message> seed = const [],
}) async {
  final fs = MemoryFileSystem();
  final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
  final agent = Agent(
    model: Model(
      id: 'scripted-model',
      name: 'scripted-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://endpoint.invalid',
      contextWindow: contextWindow,
      maxTokens: 4096,
      input: const ['text'],
    ),
    systemPrompt: '',
    streamFunction: stream,
    toolRegistry: ToolRegistry(tools),
  );
  final logs = <String>[];
  final notices = <String>[];
  final runner = ExtensionCompactionRunner(
    session: session,
    agent: agent,
    contextWindowCap: contextWindowCap,
    log: logs.add,
    notice: notices.add,
  );
  // Host parity: the SW shell persists every completed message into the
  // session tree (agent_host._persistMessage) — the compactor reads the
  // SESSION branch, not just the live state.
  agent.subscribe((event, cancelToken) async {
    if (event is MessageEndEvent) {
      await session.appendMessage(event.message);
    }
  });
  for (final message in seed) {
    await session.appendMessage(message);
  }
  if (seed.isNotEmpty) {
    agent.state.messages = await session.buildContextMessages();
  }
  return _Rig(session, agent, runner, logs, notices);
}

UserMessage _user(String text) => UserMessage.text(text);

AssistantMessage _assistantSeed(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'scripted-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage _toolResult(String id, String text) => ToolResultMessage(
  toolCallId: id,
  toolName: 'echo',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

void main() {
  group('AC1 — relief parity (issue #387, the loop guard contract)', () {
    test('a mid-turn over-window transcript triggers exactly ONE relief pass '
        'and the retried request goes out under-window', () async {
      // Mirror of the app's IT-3 shape: a ~8500-token tool result
      // balloons the transcript mid-turn against an 8192 window.
      final call = ToolCall(
        id: 'tc-1',
        name: 'echo',
        arguments: const {'x': 'go'},
      );
      final echo = AgentTool(
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
      final rig = await _rig(
        _toolCallStream(call, 'continued'),
        contextWindow: 8192,
        tools: [echo],
      );
      // The exact wiring the host installs in _init (gh-2059 AC1).
      rig.agent.overWindowRelief = (overWindow) => rig.runner.relieveOverWindow(
        overWindow,
        runToken: rig.agent.cancelToken,
      );

      await rig.agent.prompt('go');

      expect(rig.runner.reliefCount, 1, reason: 'exactly one relief pass');
      final last = rig.agent.state.messages.last;
      expect(last, isA<AssistantMessage>());
      final lastText = (last as AssistantMessage).content.single as TextContent;
      expect(
        lastText.text,
        'continued',
        reason: 'the turn completed after the relief, not a refusal',
      );
      // The retried request rides a transcript under the effective
      // window (the guard's own basis).
      expect(rig.requestTokens, lessThan(8192));
      // The ballooned tool result was compacted away.
      final rendered = rig.agent.state.messages
          .map((m) => estimateTokens(m))
          .reduce((a, b) => a + b);
      expect(rendered, lessThan(8192));
      // No failure notice: the relief is a success story in the log.
      expect(rig.notices, isEmpty);
      expect(rig.logs.join('\n'), contains('over-window relief'));
    });
  });

  group('AC2 — manual /compact (SW half; the panel half is the notice '
      'event the relay renders)', () {
    test('a /compact pass runs unconditionally and emits the before/after '
        'receipt, never a transcript message', () async {
      final rig = await _rig(textStream('turn reply'));
      await rig.session.appendMessage(_user('u1${'a' * 1200}'));
      await rig.session.appendMessage(_assistantSeed('r1${'b' * 1200}'));
      await rig.session.appendMessage(_user('u2${'c' * 1200}'));
      rig.agent.state.messages = await rig.session.buildContextMessages();
      final beforeCount = rig.agent.state.messages.length;

      final outcome = await rig.runner.manualCompact();

      expect(outcome.ran, isTrue);
      expect(outcome.after, lessThan(outcome.before));
      expect(
        rig.notices.join('\n'),
        contains('compacted: ${outcome.before} → ${outcome.after} tokens'),
        reason: 'the AC2 receipt: before/after tokens on the notice',
      );
      // The pass compacted the transcript…
      expect(rig.agent.state.messages.length, lessThan(beforeCount));
      // Never a transcript entry: /compact added no user message.
      expect(
        rig.agent.state.messages.map(
          (m) => m is UserMessage
              ? (m.content is String ? m.content as String : '')
              : '',
        ),
        everyElement(isNot(contains('/compact'))),
        reason: 'the pass compacted; it did not append a /compact message',
      );
    });

    test(
      'an empty transcript says "nothing to compact" without a pass',
      () async {
        final rig = await _rig(textStream('turn reply'));
        final outcome = await rig.runner.manualCompact();
        expect(outcome.ran, isFalse);
        expect(rig.notices.single, contains('nothing to compact'));
      },
    );
  });

  group('AC3 — the under-window invariant over generated transcripts', () {
    test('after the manual path: under the trigger OR a visible notice, '
        'including the newest-bigger-than-budget case', () async {
      final random = Random(2059);
      for (var i = 0; i < 24; i++) {
        final window = 400 + random.nextInt(1600);
        final rig = await _rig(textStream('reply'), contextWindow: window);
        final pairs = 1 + random.nextInt(6);
        for (var p = 0; p < pairs; p++) {
          final size = 100 + random.nextInt(1200);
          await rig.session.appendMessage(_user('u$p${'a' * size}'));
          await rig.session.appendMessage(_assistantSeed('r$p${'b' * size}'));
        }
        // The border case: a newest single message bigger than the
        // kept region (a coalesced DOM dump).
        if (i % 4 == 0) {
          await rig.session.appendMessage(
            _user('huge newest ${'z' * (6000 + random.nextInt(6000))}'),
          );
        }
        rig.agent.state.messages = await rig.session.buildContextMessages();
        final transcriptBefore = rig.requestTokens;

        await rig.runner.manualCompact();

        final wiring = rig.runner.wiring;
        final trigger =
            wiring.conversationWindow - wiring.settings.reserveTokens;
        final under = rig.requestTokens < trigger;
        final noticed = rig.notices.isNotEmpty;
        expect(
          under || noticed,
          isTrue,
          reason:
              'iteration $i (window $window, estimate '
              '$transcriptBefore → ${rig.requestTokens}): the live context '
              'must land under the trigger ($trigger) or a visible notice '
              'must fire — never a silent stuck state',
        );
        // The transcript is never silently truncated: whatever remains
        // is either under the trigger, or every compaction avenue fired
        // a notice while the newest message survives.
        if (!under) {
          expect(
            rig.agent.state.messages,
            isNotEmpty,
            reason: 'the valve null path keeps the transcript intact',
          );
        }
      }
    });
  });

  group('AC4 — visibility (gh-1077 AC2 shape)', () {
    test('every pass emits ≥1 SW log line with the honest numbers', () async {
      final rig = await _rig(textStream('reply'));
      for (var i = 0; i < 3; i++) {
        await rig.session.appendMessage(_user('u$i${'a' * 1200}'));
        await rig.session.appendMessage(_assistantSeed('r$i${'b' * 1200}'));
      }
      rig.agent.state.messages = await rig.session.buildContextMessages();

      await rig.runner.manualCompact();

      final passLines = rig.logs
          .where((l) => l.contains('[fah][sw] compaction pass'))
          .toList();
      expect(passLines, isNotEmpty, reason: 'AC4: ≥1 SW line per pass');
      expect(
        passLines.first,
        allOf(
          contains('tokens'),
          contains('engine='),
          contains('hidden='),
          contains('summarized='),
        ),
        reason: 'AC11: the line alone answers what the pass dropped',
      );
      expect(rig.logs.join('\n'), contains('[fah][sw] compaction done'));
    });

    test('a failed pass adds ≥1 panel system notice', () async {
      final rig = await _rig(
        _failingSummarizerStream('summary backend down', 'turn reply'),
      );
      for (var i = 0; i < 3; i++) {
        await rig.session.appendMessage(_user('u$i${'a' * 1200}'));
        await rig.session.appendMessage(_assistantSeed('r$i${'b' * 1200}'));
      }
      rig.agent.state.messages = await rig.session.buildContextMessages();

      await rig.runner.manualCompact();

      expect(
        rig.notices.join('\n'),
        contains(extCompactionFailureNoticeLead),
        reason: 'AC4/gh-1077 AC2: the failure notice fires',
      );
      expect(
        rig.logs.join('\n'),
        contains('summary backend down'),
        reason: 'AC11: the log alone answers why it failed',
      );
      // Failure-safe: nothing invented, nothing lost silently.
      expect(rig.agent.state.messages.length, 6);
    });
  });

  group('AC5 — the re-fire ladder', () {
    test('a still-over pass re-fires exactly once, then the exhaustion '
        'notice — no infinite loop', () async {
      final rig = await _rig(textStream('reply'));
      // Window 512 → reserve 128, keep 256; trigger = 384. The newest
      // message (~400 tokens) exceeds the kept region (256): the valve's
      // null path keeps it, so every pass lands over the trigger.
      await rig.session.appendMessage(_user('u1${'a' * 1200}'));
      await rig.session.appendMessage(_assistantSeed('r1${'b' * 1200}'));
      await rig.session.appendMessage(_user('huge${'z' * 1600}'));
      rig.agent.state.messages = await rig.session.buildContextMessages();

      final outcome = await rig.runner.manualCompact();

      final wiring = rig.runner.wiring;
      final trigger = wiring.conversationWindow - wiring.settings.reserveTokens;
      // Exactly one re-fire: two factory runs total ('compaction done'
      // fires once per run), then the notice.
      final doneLines = rig.logs
          .where((l) => l.contains('[fah][sw] compaction done'))
          .length;
      expect(doneLines, 2, reason: 'initial pass + exactly one re-fire');
      expect(rig.logs.join('\n'), contains('re-firing'));
      expect(outcome.exhausted, isTrue);
      expect(rig.notices.join('\n'), contains(extCompactionExhaustedNotice));
      // The transcript is intact, never silently dropped.
      expect(rig.agent.state.messages, isNotEmpty);
      expect(
        rig.agent.state.messages.any(
          (m) => m is UserMessage && estimateTokens(m) > 300,
        ),
        isTrue,
        reason: 'the unsuppressible newest message survives',
      );
      expect(rig.requestTokens, greaterThanOrEqualTo(trigger));
    });
  });

  group('AC6 — incident replay (the 128,040 regression)', () {
    test('30 turns of ~60k-char tool results against a 128000 window '
        'recover to under-window via the settle pass', () async {
      final call = ToolCall(
        id: 'tc-seed',
        name: 'browser_read_dom',
        arguments: const {'selector': '#form'},
      );
      final rig = await _rig(textStream('done'), contextWindow: 128000);
      for (var i = 0; i < 30; i++) {
        await rig.session.appendMessage(_user('fill field $i'));
        await rig.session.appendMessage(
          AssistantMessage(
            content: [
              TextContent(text: 'reading the page'),
              ToolCall(id: 'tc-$i', name: call.name, arguments: call.arguments),
            ],
            api: 'test-api',
            provider: 'test-provider',
            model: 'scripted-model',
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.utc(2026),
          ),
        );
        await rig.session.appendMessage(
          _toolResult('tc-$i', 'dom' * 20000), // ~60k chars ≈ 15k tokens
        );
      }
      rig.agent.state.messages = await rig.session.buildContextMessages();
      // The incident shape: ~450k estimated tokens against 128000.
      expect(rig.requestTokens, greaterThan(128000));

      final freed = await rig.runner.compactIfDue();

      expect(freed, isTrue, reason: 'the settle pass freed the window');
      final wiring = rig.runner.wiring;
      final trigger = wiring.conversationWindow - wiring.settings.reserveTokens;
      expect(
        rig.requestTokens,
        lessThan(trigger),
        reason:
            'the exact 128,040 outcome is impossible now: the pass '
            'lands UNDER the trigger or fires the notice',
      );
      expect(rig.notices, isEmpty, reason: 'no refusal survived');
      expect(rig.logs.join('\n'), contains('[fah][sw] compaction pass'));
    });
  });

  group('AC8 — cancel parity (issue #1085)', () {
    test(
      'a cancelled relief returns null with NO failed-pass notice',
      () async {
        final rig = await _rig(textStream('reply'));
        for (var i = 0; i < 4; i++) {
          await rig.session.appendMessage(_user('u$i${'a' * 1200}'));
          await rig.session.appendMessage(_assistantSeed('r$i${'b' * 1200}'));
        }
        rig.agent.state.messages = await rig.session.buildContextMessages();
        final source = CancelTokenSource()..cancel('user abort');

        final relieved = await rig.runner.relieveOverWindow(
          rig.agent.state.messages,
          runToken: source.token,
        );

        expect(relieved, isNull);
        expect(rig.runner.reliefCount, 1);
        expect(
          rig.notices,
          isEmpty,
          reason:
              'a user abort surfaces as aborted, never as a '
              'failed-pass notice',
        );
      },
    );

    test('a cancelled manual /compact surfaces "compaction interrupted", '
        'never a failed-pass report', () async {
      final source = CancelTokenSource();
      final rig = await _rig(
        _cancelOnSummarize(source, 'cancelled mid-pass', 'turn reply'),
      );
      for (var i = 0; i < 3; i++) {
        await rig.session.appendMessage(_user('u$i${'a' * 1200}'));
        await rig.session.appendMessage(_assistantSeed('r$i${'b' * 1200}'));
      }
      rig.agent.state.messages = await rig.session.buildContextMessages();

      Object? caught;
      try {
        await rig.runner.manualCompact(runToken: source.token);
        // The first summarizer call cancels the run; the pass fails as
        // cancelled — the runner converts it to the interruption notice
        // and rethrows.
        fail('expected CancelledException');
      } on CancelledException {
        caught = true;
      }

      expect(caught, isTrue);
      expect(rig.notices.join('\n'), contains('compaction interrupted'));
      expect(
        rig.notices.join('\n'),
        isNot(contains(extCompactionFailureNoticeLead)),
        reason: 'never a failed-pass mutation report',
      );
    });
  });

  group('AC10 — no hand-rolled compaction constants (grep guard)', () {
    test('the extension host carries no CompactionSettings.forWindow / '
        'contextWindow: 128000 literals', () {
      for (final file in [
        'src/agent_host.dart',
        'src/providers.dart',
        'lib/src/host_compaction.dart',
      ]) {
        final source = File(file).readAsStringSync();
        expect(
          source.contains('CompactionSettings.forWindow'),
          isFalse,
          reason: '$file must consume the shared resolution',
        );
        expect(
          source.contains('contextWindow: 128000'),
          isFalse,
          reason: '$file must not pin a per-host window constant',
        );
      }
    });
  });

  group('slash dispatch (AC2 / unknown-slash parity)', () {
    test('/compact variants route to the manual pass', () {
      expect(parseSlashInput('/compact'), const SlashCompact());
      expect(parseSlashInput('  /compact  '), const SlashCompact());
      expect(parseSlashInput('/compact now'), const SlashCompact());
    });

    test('a bare unknown token is refused; multi-word and path-like '
        'input stay messages', () {
      expect(parseSlashInput('/foo'), const SlashUnknown('/foo'));
      expect(parseSlashInput('/compactX'), const SlashUnknown('/compactX'));
      // CLI parity: a message that starts with a path-like token is
      // input, never a refused command.
      expect(parseSlashInput('/foo bar'), isNull);
      expect(parseSlashInput('/a/b'), isNull);
      expect(parseSlashInput('hello'), isNull);
      expect(parseSlashInput('/'), isNull);
    });
  });

  group('AC7 — wiring resolution joins the parity contract', () {
    test('the extension resolution rides the shared wiring with a cap', () {
      final runner0 = _rigForWiring(cap: null);
      final runner64 = _rigForWiring(cap: 64000);
      expect(runner0.window, 200000);
      expect(runner64.window, 64000);
      expect(
        runner64.conversationWindow - runner64.reserve,
        lessThan(runner0.conversationWindow - runner0.reserve),
        reason: 'the cap clamps the trigger through the shared resolution',
      );
    });
  });
}

/// Wiring-resolution probe rig (no compaction runs — window numbers
/// only).
({int window, int conversationWindow, int reserve}) _rigForWiring({
  required int? cap,
}) {
  final model = Model(
    id: 'probe',
    name: 'probe',
    api: 'test-api',
    provider: 'test-provider',
    baseUrl: 'https://endpoint.invalid',
    contextWindow: 200000,
    maxTokens: 4096,
    input: const ['text'],
  );
  final wiring = resolveExtensionCompactionWiring(
    mainModel: model,
    systemOverheadTokens: 0,
    contextWindowCap: cap,
  );
  return (
    window: wiring.window,
    conversationWindow: wiring.conversationWindow,
    reserve: wiring.settings.reserveTokens,
  );
}
