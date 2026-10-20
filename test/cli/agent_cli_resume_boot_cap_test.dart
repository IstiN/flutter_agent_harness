// gh-1425 AC3/AC5 — the resume boot cap: an over-window session runs one
// forced compaction pass at IDLE BOOT, before any user message, so the ctx
// meter never idles above the window (S1: "the meter faithfully displayed
// 143% and waited"). Degradation (AC5): a dead summarizer degrades to the
// existing local-trim valve with a visible note — the boot survives and the
// next request is still ≤ window.

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
        reason: 'boot settles instantly with the local-trim note '
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
    'AC5: a dead summarizer at boot degrades to the local trim with a '
    'visible note — the boot survives and the next request is ≤ window '
    '(over-trigger-under-window keeps the LM boot cap)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // 115 kept messages ≈ 115k tokens: over the 114,688 trigger, UNDER
      // the 131,072 window — the over-trigger case that still runs the LM
      // boot cap (over-window now trims locally and instantly instead).
      final env = await seedOverWindow('boot-cap-target', keptCount: 115);
      final stream = FakeStreamFunction([
        // The boot cap's summarizer attempt FAILS.
        [
          ErrorEvent(
            reason: StopReason.error,
            error: testAssistant(
              stopReason: StopReason.error,
              errorMessage: 'BOOM summarizer endpoint down',
            ),
          ),
        ],
        // The first user turn's answer.
        textTurn('answered after degraded boot'),
      ]);
      final agent = cli(env, stream, model: _bigModel);

      final run = agent.run();
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the failed cap attempt settles at boot',
      );
      io.sendLine('go');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'the turn proceeds on the trimmed context',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // AC5: the failure is VISIBLE (the local-trim valve's note), never
      // a silent over-window boot, and the boot/turn survive.
      expect(output, contains('[context trimmed]'));
      expect(output, contains('answered after degraded boot'));
      // The trimmed request is still ≤ the window (never a silent
      // over-window request).
      expect(requestTokensOf(stream.contexts[1]), lessThanOrEqualTo(_window));
    },
  );

  test(
    'AC3 backstop: a boot cap that dies to an UNEXPECTED throw prints a '
    'visible note — a crashed cap must not look like the pre-fix 143% '
    'state (review thread: the on-Object catch failed silently)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedOverWindow('boot-cap-target', keptCount: 115);
      final stream = FakeStreamFunction([
        // The cap's summarizer SUCCEEDS and the transcript is restamped —
        // then rendering the report block throws (broken stdout). The
        // unexpected-throw class the on-Object backstop exists for.
        textTurn('compacted boot summary'),
        // The crashed cap schedules a forced retry before the next turn
        // (the note says so) — that retry consumes a summarizer call
        // (a no-work pass: the branch is already compacted at the leaf).
        textTurn('retry pass summary'),
        // The 'go' turn itself.
        textTurn('FINAL ANSWER after the crashed report'),
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
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the crashed cap settles at boot',
      );
      brokenIo.sendLine('go');
      await waitForIt(
        () => stream.calls >= 3 && !agent.isBusy,
        reason: 'the turn proceeds after the crashed cap (and its forced '
            'retry pass)',
      );
      brokenIo.sendLine('/exit');
      await run;

      final output = brokenIo.out.toString();
      // THE FIX: the backstop is LOUD — a dim one-liner names the crash
      // and the still-over-window state, diagnosable from the transcript
      // alone (the repo convention for every swallowed compaction
      // failure).
      expect(output, contains('[resume] boot compaction failed'));
      expect(output, contains('stdout pipe broken'));
      // Boot survival is unchanged: the turn answers…
      expect(output, contains('FINAL ANSWER after the crashed report'));
      // …on the CAPPED context (the transcript was restamped before the
      // report render crashed).
      expect(
        requestTokensOf(stream.contexts.last),
        lessThanOrEqualTo(_bigWindow - 16384),
      );
    },
  );

  test(
    'AC3 stale-abort: an abort of the PREVIOUS session does not suppress '
    'the next session\'s boot cap — _switchToMetadata clears the '
    'CLI-lifetime _runAbortRequested (review: the flag is only reset at '
    'the next prompt run, so abort → /resume skipped the cap and the '
    'meter idled over 100% until the first prompt)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Session A ('small-boot', created first): tiny, boots under-window.
      // Session B ('boot-cap-target', created second): over-window — the
      // /resume target (the repo lists sessions newest-first).
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final small = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await small.appendSessionName('small-boot');
      await small.appendMessage(UserMessage.text('tiny'));
      await seedOverWindow('boot-cap-target', into: env, keptCount: 115);

      // Turn 1 hangs until the interrupt cancels it (the Ctrl+C leg);
      // the boot cap's summarizer ladder after the switch consumes the
      // scripted turns (chunked summarization issues several calls —
      // script generously so the ladder never starves into local-trim).
      final cap = FakeStreamFunction([
        textTurn('compacted boot summary chunk one'),
        textTurn('compacted boot summary chunk two'),
        textTurn('compacted boot summary combined'),
        textTurn('compacted boot summary retry'),
        textTurn('compacted boot summary retry two'),
        textTurn('compacted boot summary retry three'),
      ]);
      final hang = AbortableStreamFunction();
      var hung = false;
      AssistantMessageEventStream streamCall(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        if (!hung) {
          hung = true;
          return hang.call(model, context, cancelToken: cancelToken);
        }
        return cap.call(model, context);
      }

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
        streamFunction: streamCall,
      );

      final run = agent.run();
      io.sendLine('go');
      await waitForIt(
        () => agent.isBusy,
        reason: 'the hanging turn is in flight',
      );
      // Ctrl+C: _abortRunOrCompaction sets the CLI-lifetime flag.
      io.interrupt();
      await waitForIt(() => !agent.isBusy, reason: 'the aborted turn settles');
      expect(io.out.toString(), contains('Operation aborted'));

      // /session switches to the over-window session WITHOUT an
      // intervening prompt run (the only place the stale flag used to be
      // cleared): the boot cap must still run, at idle, before any user
      // input. (/resume would pick the CURRENT session here — the aborted
      // run made it the most recently ACTIVE one.)
      io.sendLine('/session boot-cap-target');
      await waitForIt(
        () => cap.calls >= 1 && !agent.isBusy,
        reason:
            'the boot cap runs on the resumed (over-window) session '
            'despite the previous session\'s abort',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // THE FIX: the cap's summarizer pass completed — the rendered
      // 'auto-compacted' report (not the AC5 '[context trimmed]' valve,
      // and never a silent skip).
      expect(output, contains('auto-compacted'));
      expect(output, isNot(contains('[context trimmed]')));
      // THE SYMPTOM (review wording): the resumed meter must NOT idle
      // over 100% — the last rendered ctx gauge after the switch is the
      // capped context (pre-fix the skipped cap left it at ~154%).
      final ctxMatches = RegExp(r'ctx (\d+)%').allMatches(output).toList();
      expect(ctxMatches, isNotEmpty);
      expect(
        int.parse(ctxMatches.last.group(1)!),
        lessThanOrEqualTo(100),
        reason:
            'the resumed session boots with the meter at or below '
            '100% — the stale abort must not skip the boot cap',
      );
    },
  );
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
