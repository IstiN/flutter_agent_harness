// gh-2259 — the E1 pre-emptive pass consumption boundary. The consuming
// gate (`_messageCapGateReached`) was called on EVERY `_maybeAutoCompact`
// path, including the unforced post-run and over-window folds: the fold
// consumed the armed one-shot pass and executed ZERO passes (the engine
// short-circuits unforced runs under the token trigger), so the remedy a
// cap-unknown refusal armed evaporated and the next request re-learned
// the refusal the hard way.
//
// The contract under test: the armed pass survives until a pass actually
// EXECUTES — the next prompt's pre-flight (`forceE1Pass: true`) consumes
// it with a FORCED compaction, exactly once.

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _bigWindow = 131072;
// CompactionSettings.forWindow(131072): trigger 114688 — the tiny seeded
// transcript sits far under it, so the armed E1 pass is the ONLY
// compaction trigger (the gh-1680 shape: token-healthy, cap-unknown).
Model get _bigModel => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _bigWindow,
  maxTokens: 4096,
);

/// A cap-UNKNOWN refusal turn: no parseable message number —
/// `learnFromRefusal` arms the E1 one-shot pre-emptive pass.
List<AssistantMessageEvent> _capUnknownRefusalTurn() {
  final msg = testAssistant(
    stopReason: StopReason.error,
    errorMessage: 'Error: 400 too many messages in one request',
  );
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

/// A context-window-exhausted error turn — drives the over-window
/// continuation funnel on the run that follows.
List<AssistantMessageEvent> _windowExhaustedTurn() {
  final msg = testAssistant(
    stopReason: StopReason.error,
    errorMessage:
        'Context window exhausted: the outgoing request exceeded '
        'the model window',
  );
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

/// Shape-discriminating fake stream: compaction-side calls (the chunked
/// summarizer ladder) carry a single-message context and count in
/// [chunkCalls]; real turn calls carry history and replay [turnScript]
/// in order (the last entry repeats). The chunk counter is the pass
/// receipt the assertions read: it moves ONLY when a compaction pass
/// actually executes.
class _CapAwareStream {
  _CapAwareStream(this.turnScript);

  final List<List<AssistantMessageEvent>> turnScript;
  final contexts = <Context>[];

  int _turnCalls = 0;
  int _chunkCalls = 0;
  int get chunkCalls => _chunkCalls;

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
    final stream = AssistantMessageEventStream();
    final List<AssistantMessageEvent> events;
    if (context.messages.length > 1) {
      final i = _turnCalls++;
      events = i < turnScript.length ? turnScript[i] : turnScript.last;
    } else {
      events = textTurn('compacted summary chunk ${++_chunkCalls}');
    }
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// Seeds a token-healthy session: ~30 kept messages ≈ ~30k tokens —
  /// far under the 114,688 token trigger (the armed E1 pass is the ONLY
  /// compaction trigger), but over the 20,000 keep-recent cut of the
  /// 131072 window, so the forced pre-flight pass genuinely summarizes
  /// (real pass receipts). A cap-unknown refusal arms the E1 pass there
  /// and the deterministic relief no-ops (the context is under the
  /// window), so the pass is the only pending remedy.
  Future<MemoryExecutionEnv> seedTinySession() async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('cap-pass-target');
    for (var i = 0; i < 30; i++) {
      await seed.appendMessage(UserMessage.text('m$i ${'a' * 4000}'));
    }
    return env;
  }

  AgentCli cli(MemoryExecutionEnv env, _CapAwareStream stream) => AgentCli(
    config: AgentCliConfig(
      model: _bigModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'cap-pass-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
    ),
    io: io,
    streamFunction: stream.call,
  );

  test(
    'gh-2259 AC1: the post-run fold must NOT consume the armed E1 pass — '
    'the next prompt\'s pre-flight executes it as a forced pass',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      const secondAnswer = 'answer after the pre-flight pass';
      final env = await seedTinySession();
      final stream = _CapAwareStream([
        _capUnknownRefusalTurn(), // turn 1: arms the pass (relief no-ops)
        textTurn('healed retry answer'), // turn 2: the coalesce retry
        textTurn(secondAnswer), // turn 3+; repeats for later prompts
      ]);
      final agent = cli(env, stream);

      int answerCount(String needle) =>
          RegExp(RegExp.escape(needle)).allMatches(io.out.toString()).length;

      final run = agent.run();
      await waitForIt(() => !agent.isBusy, reason: 'boot settles idle');
      io.sendLine('go');
      await waitForIt(
        () =>
            !agent.isBusy && io.out.toString().contains('healed retry answer'),
        reason:
            'the refusal heals and the run settles normally '
            '(so the post-run fold fires)',
      );
      // The run settled: the post-run fold ran. Zero compaction-side LM
      // calls so far — the relief no-oped and the fold ran unforced.
      final chunksAfterRun = stream.chunkCalls;

      io.sendLine('go');
      await waitForIt(
        () => !agent.isBusy && answerCount(secondAnswer) >= 1,
        reason: 'the second prompt settles on its own answer',
      );
      // THE CONTRACT: the armed pass survived the post-run fold and the
      // second prompt's pre-flight EXECUTED it — a forced pass with at
      // least one pass receipt (summarizer call + the auto-compacted
      // report). Consumed-then-lost (the bug) runs zero passes here.
      expect(
        stream.chunkCalls,
        greaterThan(chunksAfterRun),
        reason:
            'the pre-flight pass issued summarizer call(s) — the '
            'armed E1 pass executed instead of evaporating',
      );
      expect(io.out.toString(), contains('auto-compacted'));

      // REG (exactly once): the pass is one-shot — the third prompt
      // issues no further compaction call.
      final chunksAfterPass = stream.chunkCalls;
      io.sendLine('go');
      await waitForIt(
        () => !agent.isBusy && answerCount(secondAnswer) >= 2,
        reason: 'the third prompt answers',
      );
      expect(
        stream.chunkCalls,
        chunksAfterPass,
        reason: 'the E1 pass fired exactly once — no re-arm, no repeat',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'gh-2259 AC2: the over-window funnel fold must NOT consume the armed '
    'E1 pass — the next prompt\'s pre-flight executes it',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      const secondAnswer = 'answer after the pre-flight pass';
      final env = await seedTinySession();
      final stream = _CapAwareStream([
        _capUnknownRefusalTurn(), // turn 1: arms the pass (relief no-ops)
        _windowExhaustedTurn(), // heal retry over-windows: funnel fires
        textTurn(secondAnswer), // turn 3: the follow-up prompt's answer
      ]);
      final agent = cli(env, stream);
      int answerCount(String needle) =>
          RegExp(RegExp.escape(needle)).allMatches(io.out.toString()).length;

      final run = agent.run();
      await waitForIt(() => !agent.isBusy, reason: 'boot settles idle');
      io.sendLine('go');
      await waitForIt(
        () =>
            !agent.isBusy &&
            io.out.toString().contains('error: the transcript is still'),
        reason:
            'the heal retry over-windows, the funnel exhausts its '
            'bounded attempts and prints the loud verdict',
      );
      final chunksAfterFunnel = stream.chunkCalls;

      io.sendLine('go');
      await waitForIt(
        () => !agent.isBusy && answerCount(secondAnswer) >= 1,
        reason: 'the second prompt settles on its own answer',
      );
      // THE CONTRACT: the armed pass survived the funnel's unforced
      // zero-pass folds and the next pre-flight executed it.
      expect(
        stream.chunkCalls,
        greaterThan(chunksAfterFunnel),
        reason:
            'the funnel consumed the pass without executing it — '
            'the pre-flight must still fire the forced pass',
      );
      expect(io.out.toString(), contains('auto-compacted'));

      io.sendLine('/exit');
      await run;
    },
  );

  test('gh-2259 AC4: the consuming gate is callable only from the forced '
      'branch — its single call site rides the e1PassPending flag', () {
    // The grep-guard the card mandates: `_messageCapGateReached`
    // consumes the one-shot pass, so it may only run where the pass
    // will actually execute (the `e1PassPending ?` forced branch of
    // `_maybeAutoCompact`); every other path peeks.
    final source = File(
      'lib/src/cli/agent_cli_compaction.dart',
    ).readAsStringSync();
    final lines = source.split('\n');
    final callLines = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('_messageCapGateReached(') &&
          !lines[i].trimLeft().startsWith('bool _messageCapGateReached(')) {
        callLines.add(i);
      }
    }
    expect(callLines, hasLength(1), reason: 'one consuming call site');
    final callLine = lines[callLines.first].trim();
    expect(
      callLine,
      startsWith('? _messageCapGateReached()'),
      reason:
          'the consuming gate may only appear as the forced branch '
          'of the e1PassPending ternary — anywhere else it strips an '
          'armed pass the fold will not execute',
    );
  });
}
