// gh-1425 AC3/AC5 — the resume boot cap: an over-window session runs one
// forced compaction pass at IDLE BOOT, before any user message, so the ctx
// meter never idles above the window (S1: "the meter faithfully displayed
// 143% and waited"). Degradation (AC5): a dead summarizer degrades to the
// existing local-trim valve with a visible note — the boot survives and the
// next request is still ≤ window.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
const _reserve = 8192;
// CompactionSettings.forWindow(32768): reserve = min(16384, window ~/ 4).
final _threshold = _window - _reserve;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

// The LM-boot-cap tests (AC5/backstop/stale-abort) need a resume that is
// OVER THE TRIGGER but UNDER THE WINDOW — the domain where the boot cap
// still runs an LLM pass (over-window now trims locally and instantly).
// A 131k window widens the (trigger, window) band enough that the seed's
// token math holds regardless of the exact system-prompt/tool overhead.
const _bigWindow = 131072;
// CompactionSettings.forWindow(131072): reserve 16384 -> trigger 114688.
Model get _bigModel => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _bigWindow,
  maxTokens: 4096,
);

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// Seeds a session with a reachable classic compaction boundary whose
  /// post-walk projection is far over the 24,576-token threshold: 40 kept
  /// messages priced ~1000 tokens each plus the summary. Pass [into] to
  /// seed into an EXISTING env (a test that needs several sessions in one
  /// repo, e.g. the stale-abort switch test).
  Future<MemoryExecutionEnv> seedOverWindow(
    String name, {
    MemoryExecutionEnv? into,
    int keptCount = 40,
  }) async {
    final env = into ?? MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (same pattern as
    // agent_cli_test) so the scripted turns feed only the cap + the turn.
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    for (var i = 0; i < 10; i++) {
      await seed.appendMessage(UserMessage.text('old$i ${'a' * 4000}'));
    }
    final firstKept = await seed.appendMessage(
      UserMessage.text('kept0 ${'a' * 4000}'),
    );
    await seed.appendCompaction(
      summary: 'earlier marathon context',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < keptCount; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }
    return env;
  }

  AgentCli cli(
    MemoryExecutionEnv env,
    FakeStreamFunction stream, {
    Model? model,
  }) => AgentCli(
    config: AgentCliConfig(
      model: model ?? _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'boot-cap-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
    ),
    io: io,
    streamFunction: stream.call,
  );

  int requestTokensOf(Context context) =>
      estimateContextTokens(context.messages).tokens +
      estimateRequestOverheadTokens(
        context.systemPrompt,
        context.tools ?? const [],
      );

  test(
    'AC3 (goal_builder contract): an over-window resume boots INSTANTLY — '
    'the local-trim valve caps it with NO LM call — and the next request '
    'fits the window',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedOverWindow('boot-cap-target'); // ~40k > 32768
      final stream = FakeStreamFunction([
        // NO boot-time summarizer call exists anymore — the FIRST stream
        // call is the first user turn.
        textTurn('answered after instant boot cap'),
      ]);
      final agent = cli(env, stream);

      final run = agent.run();
      await waitForIt(
        () => io.out.toString().contains('trimmed locally') && !agent.isBusy,
        reason:
            'boot settles instantly with the local-trim note '
            '(no LM cap for over-window)',
      );
      // The whole point of the goal_builder fix: zero provider calls at
      // boot — the old LM cap here took 3.5 minutes on a slow summarizer
      // and read as a hung open.
      expect(stream.calls, 0);
      expect(io.out.toString(), contains('trimmed locally'));

      io.sendLine('go');
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the first user turn answers on the trimmed context',
      );
      io.sendLine('/exit');
      await run;

      final turnContext = stream.contexts.last;
      expect(requestTokensOf(turnContext), lessThanOrEqualTo(_threshold));
      // The trim genuinely dropped the old kept messages.
      final texts = [
        for (final m in turnContext.messages)
          if (m is UserMessage) messageText(m),
      ];
      expect(texts.where((t) => t.startsWith('kept1 ')), isEmpty);
    },
  );

  test(
    'AC5 (lazy rework): an over-trigger-UNDER-window resume boots with '
    'ZERO LM calls; a dead summarizer degrades at the FIRST TURN\'s '
    'pre-flight — the local-trim valve caps it with a visible note and '
    'the request is still ≤ window',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // 115 kept messages ≈ 115k tokens: over the 114,688 trigger, UNDER
      // the 131,072 window — the lazy regime: boot defers, the first
      // turn's pre-flight owns the durable compaction.
      final env = await seedOverWindow('boot-cap-target', keptCount: 115);
      final stream = FakeStreamFunction([
        // The first turn's pre-flight summarizer attempt FAILS.
        [
          ErrorEvent(
            reason: StopReason.error,
            error: testAssistant(
              stopReason: StopReason.error,
              errorMessage: 'BOOM summarizer endpoint down',
            ),
          ),
        ],
        // The turn's answer proceeds on the locally-trimmed context.
        textTurn('answered after degraded pre-flight'),
      ]);
      final agent = cli(env, stream, model: _bigModel);

      final run = agent.run();
      // LAZY BOOT: settles instantly, zero provider calls, no compaction
      // PASS (the old synchronous LM boot cap here cost minutes and read
      // as a hung open — the yoclip incident). The regime does get a dim
      // receipt note (gh-1729 review) — asserted below. Wait for the
      // status line: `!isBusy` alone is also true BEFORE the async boot
      // starts.
      await waitForIt(
        () => io.out.toString().contains('ctx ') && !agent.isBusy,
        reason: 'boot settles instantly without any compaction pass',
      );
      expect(stream.calls, 0);
      expect(
        io.out.toString(),
        contains('compaction deferred to the first message'),
      );

      io.sendLine('go');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'the degraded pre-flight + the turn answer settle',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // AC5: the failure is VISIBLE (the local-trim valve's note), never
      // a silent over-window request, and the boot/turn survive.
      expect(output, contains('[context trimmed]'));
      expect(output, contains('answered after degraded pre-flight'));
      // The trimmed request is still ≤ the window (never a silent
      // over-window request).
      expect(
        requestTokensOf(stream.contexts[1]),
        lessThanOrEqualTo(_bigWindow),
      );
    },
  );

  test(
    'AC3 backstop (lazy rework): a broken-stdout boot never wedges — zero '
    'LM calls at boot, and the first turn\'s pre-flight compact + answer '
    'both survive the throwing IO',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedOverWindow('boot-cap-target', keptCount: 115);
      final stream = FakeStreamFunction([
        // The first turn's pre-flight summarization ladder (the durable
        // compaction the lazy boot deferred) issues an unpredictable
        // number of chunk calls — script generously so the ladder never
        // starves, then the answer.
        for (var i = 1; i <= 40; i++)
          textTurn('compacted pre-flight summary chunk $i'),
        textTurn('FINAL ANSWER after the lazy boot'),
      ]);
      final brokenIo = _BrokenStdoutIo();
      final agent = AgentCli(
        config: AgentCliConfig(
          model: _bigModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'boot-cap-target',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: brokenIo,
        streamFunction: stream.call,
      );

      final run = agent.run();
      // LAZY BOOT under throwing IO: settles instantly, no LM call, and
      // the broken writeln cannot wedge the boot (the old synchronous
      // boot cap rendered its report through the same broken pipe).
      await waitForIt(
        () => !agent.isBusy,
        reason: 'boot settles instantly with zero LM calls',
      );
      expect(stream.calls, 0);

      brokenIo.sendLine('go');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'the pre-flight compact and the turn answer both settle',
      );
      brokenIo.sendLine('/exit');
      await run;

      final output = brokenIo.out.toString();
      // THE BACKSTOP (transplanted to the turn): the unexpected throw is
      // LOUD (a dim one-liner names the crash) and the SESSION survives —
      // the compaction itself landed (the ctx gauge drops to the capped
      // number), only the report render crashed, and the REPL exits
      // cleanly ('bye') instead of wedging.
      expect(output, contains('pre-flight compaction failed'));
      expect(output, contains('stdout pipe broken'));
      expect(output, contains('bye'));
      final ctxMatches = RegExp(r'ctx (\d+)%').allMatches(output).toList();
      expect(ctxMatches, isNotEmpty);
      expect(int.parse(ctxMatches.last.group(1)!), lessThanOrEqualTo(30));
    },
  );

  test(
    'E1 pass (gh-1729 review): a cap-unknown refusal arms the one-shot '
    'pre-emptive pass; a mid-REPL switch to an over-trigger-UNDER-window '
    'session DEFERS without consuming it — the first turn\'s pre-flight '
    'still fires the pass and compacts before the request',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Session A ('small-boot', created first): tiny, boots under-window.
      // Session B ('boot-cap-target', created second): 40 kept messages
      // (~40k tokens) — UNDER the 114,688 token trigger, so the armed E1
      // one-shot pass is the ONLY compaction trigger on the other side of
      // the switch (the reviewer's exact scenario: consumed at boot, the
      // first turn's pre-flight finds no trigger at all and the request
      // rides out uncapped).
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final small = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await small.appendSessionName('small-boot');
      await small.appendMessage(UserMessage.text('tiny'));
      await seedOverWindow('boot-cap-target', into: env, keptCount: 40);

      // Turn 1 in session A: a cap-UNKNOWN refusal (no parseable number)
      // arms the E1 one-shot pass — then the coalesce-only retry answers.
      // The switch's lazy boot must PEEK the armed pass, never consume it:
      // the first turn in session B owns the pass (and the compaction).
      //
      // Shape-discriminating fake: compaction-side calls (the chunked
      // summarizer ladder, the memory-extraction rider) carry a
      // single-message context and always get fresh chunk text; real turn
      // calls carry history and ride the refusal-heal script, with the
      // answer reserved for the LAST turn — so the script cannot go
      // misaligned no matter how many ladder calls the pass needs.
      final cap = _CapAwareSwitchStream(hangTurns: {2}, refusalTurns: {1});

      final agent = AgentCli(
        config: AgentCliConfig(
          model: _bigModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'small-boot',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        streamFunction: cap.call,
      );

      final run = agent.run();
      await waitForIt(() => !agent.isBusy, reason: 'session A boots idle');
      io.sendLine('go');
      // Turn 1: a cap-UNKNOWN refusal heals once (the relief no-ops on the
      // tiny transcript and ARMS the E1 pass via learnFromRefusal), then
      // the heal's coalesce retry hangs — the user interrupts it mid-turn
      // (the reviewer's scenario: the switch happens while the refused
      // turn is still in flight). The abort skips the post-run
      // compaction, so the armed pass is still pending when the switch
      // boots session B. This is ALSO the gh-1425 stale-abort coverage
      // the old skipped switch test carried: the abort sets
      // `_runAbortRequested`, the switch must clear it
      // (`_switchToMetadata`) so the boot gate is not suppressed (the
      // deferred note below proves it ran), and `_beginUserPrompt` must
      // clear it again so the first turn's pre-flight fires.
      await waitForIt(
        () => cap.calls >= 2 && io.out.toString().contains('retrying once'),
        reason: 'the refusal healed once and the retry stream started',
      );
      final callsAfterRefusal = cap.calls;
      io.interrupt();
      await waitForIt(
        () => !agent.isBusy && io.out.toString().contains('Operation aborted'),
        reason: 'the interrupted retry settles as an aborted turn',
      );

      io.sendLine('/session boot-cap-target');
      await waitForIt(
        () =>
            io.out.toString().contains(
              "switched to session "
              "'boot-cap-target'",
            ) &&
            !agent.isBusy,
        reason: 'the switch settles (terminal line after the async tail)',
      );
      // The lazy boot made no LM call AND kept the armed pass pending:
      // the transcript sits UNDER the token trigger, so the deferred note
      // only prints when the pending E1 pass makes the boot gate true —
      // the note IS the proof the pass survived the abort.
      expect(
        io.out.toString(),
        contains('compaction deferred to the first message'),
      );

      io.sendLine('go');
      await waitForIt(
        () =>
            io.out.toString().contains(
              'FINAL ANSWER on the compacted transcript',
            ) &&
            !agent.isBusy,
        reason: 'the first turn pre-flight compacts and then answers',
      );
      await io.close();
      unawaited(run);

      final output = io.out.toString();
      // THE CONTRACT: the armed E1 pass fired at the FIRST TURN's
      // pre-flight — the durable compaction ran BEFORE the request (never
      // a silent skip, and the request must not ride out uncapped to
      // re-learn the refusal the hard way). Turn calls 1-2 are session A's
      // refusal heal; EVERY session-B turn (the 'go' request first) must
      // ride the COMPACTED transcript — a post-run compaction with an
      // auto-continuation would leave the first request uncapped instead.
      expect(output, contains('auto-compacted'));
      final turnContexts = [
        for (final c in cap.contexts)
          if (c.messages.length > 1) c,
      ];
      final postSwitchTurns = turnContexts.skip(2).toList();
      expect(postSwitchTurns, isNotEmpty, reason: 'the switch turn ran');
      for (var i = 0; i < postSwitchTurns.length; i++) {
        expect(
          requestTokensOf(postSwitchTurns[i]),
          lessThanOrEqualTo(_bigWindow - 16384),
          reason:
              'post-switch turn #$i must ride the COMPACTED transcript — '
              'the armed E1 pass fired at the pre-flight, before the request',
        );
      }
      // 41 restored messages went in; the compacted transcript came back.
      expect(
        postSwitchTurns.first.messages.length,
        lessThan(41),
        reason:
            'the session-B turn request rode the compacted transcript, '
            'not the 41-message restore',
      );
      expect(
        cap.calls,
        greaterThan(callsAfterRefusal + 1),
        reason: 'the pre-flight pass issued summarizer call(s) before the turn',
      );
    },
  );

  // gh-1729 review: the switch regime is covered UN-SKIPPED — the old
  // skip (#1728's input-pump-vs-switch-tail wedge) is closed for this
  // flow by waiting for the switch's TERMINAL line ("switched to session
  // '…'", printed after every awaited step of _switchToMetadata,
  // including the subagent rehydrate) before any prompt is sent: the
  // input pump can no longer dispatch a queued prompt into the switch's
  // async tail. The stale-abort interaction rides its own test below (an
  // interrupted heal retry, the reviewer's E1 scenario — the level where
  // the flag actually matters). The machinery-side wedge (#1728: a
  // switch that never completes at all) stays tracked there; the
  // terminal-line wait turns any recurrence into a LOUD timeout instead
  // of a silently-wedged pass.
  test(
    'AC3 lazy switch (gh-1729 un-skip): a mid-REPL /session switch to an '
    'over-trigger session settles instantly (no LM calls) and the FIRST '
    'turn\'s pre-flight compacts before the request',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Session A ('small-boot', created first): tiny, boots under-window.
      // Session B ('boot-cap-target', created second): over-trigger but
      // under-window — the /session switch target (newest-first listing).
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final small = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await small.appendSessionName('small-boot');
      await small.appendMessage(UserMessage.text('tiny'));
      await seedOverWindow('boot-cap-target', into: env, keptCount: 115);

      // The lazy boot makes ZERO LM calls at the switch; the first turn's
      // pre-flight then runs the chunked summarization ladder (an
      // unpredictable number of single-message calls — the
      // shape-discriminating fake serves fresh chunk text to each) and
      // finally the turn answers.
      final cap = _CapAwareSwitchStream(
        answerText: 'FINAL ANSWER after the lazy switch',
      );

      final agent = AgentCli(
        config: AgentCliConfig(
          model: _bigModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'small-boot',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        streamFunction: cap.call,
      );

      final run = agent.run();
      await waitForIt(() => !agent.isBusy, reason: 'session A boots idle');

      // /session switches to the over-trigger session WITHOUT an
      // intervening prompt run. LAZY BOOT: the switch settles instantly
      // with ZERO LM calls — the durable compaction is the first turn's
      // pre-flight.
      io.sendLine('/session boot-cap-target');
      // gh-1729/#1728: wait for the switch's TERMINAL line — it prints
      // after every awaited step of _switchToMetadata — so the queued
      // prompt can never enter the switch's async tail (the #1728 wedge
      // shape). The deferred-regime note is the lazy boot's receipt.
      await waitForIt(
        () =>
            io.out.toString().contains(
              "switched to session 'boot-cap-target'",
            ) &&
            !agent.isBusy,
        reason: 'the lazy switch settles (terminal line)',
      );
      expect(
        io.out.toString(),
        contains('compaction deferred to the first message'),
      );
      expect(cap.calls, 0, reason: 'lazy boot makes no LM calls');

      io.sendLine('go');
      await waitForIt(
        () =>
            io.out.toString().contains('FINAL ANSWER after the lazy switch') &&
            !agent.isBusy,
        reason: 'the first turn pre-flight compacts and then answers',
      );
      await io.close();
      unawaited(run);

      final output = io.out.toString();
      // THE CONTRACT: the pre-flight pass completed — the rendered
      // 'auto-compacted' report (never a silent skip, never the AC5
      // local-trim valve).
      expect(output, contains('auto-compacted'));
      expect(cap.calls, greaterThanOrEqualTo(2));
      // The compacted request fits under the trigger.
      expect(
        requestTokensOf(cap.contexts.last),
        lessThanOrEqualTo(_bigWindow - 16384),
      );
    },
  );
}

/// A cap-UNKNOWN refusal turn: an error message with NO parseable message
/// number — `learnFromRefusal` arms the E1 one-shot pre-emptive pass
/// instead of learning a numeric cap (the shape PR #1695's E1 covers).
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

/// Shape-discriminating fake stream for the switch suites: compaction-side
/// calls (the chunked summarizer ladder, the memory-extraction rider) carry
/// a single-message context and always get fresh chunk text; real turn
/// calls carry history and ride a scripted turn list, whose LAST entry is
/// served for every subsequent turn. [contexts] mirrors
/// [FakeStreamFunction.contexts] so the suites' token assertions work
/// unchanged.
class _CapAwareSwitchStream {
  final contexts = <Context>[];

  /// Turn numbers (1-based) that HANG until cancelled — the mid-heal
  /// abort: the heal's retry streams forever until the user interrupts.
  final Set<int> hangTurns;

  /// Turn numbers (1-based) served as a cap-UNKNOWN refusal (the E1
  /// arming flow); every other turn gets [answerText].
  final Set<int> refusalTurns;

  /// The answer served for every non-refusal, non-hanging turn call.
  final String answerText;

  _CapAwareSwitchStream({
    this.hangTurns = const {},
    this.refusalTurns = const {},
    this.answerText = 'FINAL ANSWER on the compacted transcript',
  });

  int get calls => contexts.length;

  int _turnCalls = 0;
  int _chunkCalls = 0;

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
    if (context.messages.length > 1) _turnCalls++;
    if (context.messages.length > 1 && hangTurns.contains(_turnCalls)) {
      // Hang until cancelled, then report aborted (the AbortableStream
      // pattern): the heal's retry never completes on its own.
      stream.push(StartEvent(partial: testAssistant()));
      cancelToken?.onCancel.then((_) {
        stream.push(
          ErrorEvent(
            reason: StopReason.aborted,
            error: testAssistant(
              stopReason: StopReason.aborted,
              errorMessage: 'Operation aborted',
            ),
          ),
        );
        stream.end();
      });
      return stream;
    }
    final List<AssistantMessageEvent> events;
    if (context.messages.length <= 1) {
      events = textTurn('compacted pre-flight summary chunk ${++_chunkCalls}');
    } else {
      events = refusalTurns.contains(_turnCalls)
          ? _capUnknownRefusalTurn()
          : textTurn(answerText);
    }
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// A [FakeCliIO] whose stdout dies mid-boot: every `auto-compacted` report
/// line throws — the unexpected-throw class the boot cap's on-Object
/// backstop exists for (the compaction itself landed; only the report
/// render crashes).
class _BrokenStdoutIo extends FakeCliIO {
  @override
  void writeln(String text) {
    if (text.contains('auto-compacted')) {
      throw StateError('stdout pipe broken');
    }
    super.writeln(text);
  }
}
