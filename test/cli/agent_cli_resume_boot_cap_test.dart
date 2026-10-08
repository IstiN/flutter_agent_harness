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
  }) async {
    final env =
        into ?? MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
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
    for (var i = 1; i < 40; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }
    return env;
  }

  AgentCli cli(MemoryExecutionEnv env, FakeStreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      model: _model,
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
    'AC3: an over-window resume runs ONE forced compaction pass at idle '
    'boot — before any user message — and the next request fits the window',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedOverWindow('boot-cap-target');
      final stream = FakeStreamFunction([
        // Consumed by the BOOT CAP's summarizer — must happen before any
        // user input exists.
        textTurn('compacted boot summary'),
        // The first user turn's answer.
        textTurn('answered after boot cap'),
      ]);
      final agent = cli(env, stream);

      final run = agent.run();
      // NO user input yet: the cap's summarizer call proves the pass ran
      // at idle boot (S1: boot never used to cap anything — the meter sat
      // over 100% and waited for the first pre-flight).
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the boot cap compaction runs before any user message',
      );
      // ONE forced pass — which may legitimately issue several LLM calls
      // (chunked summarization over the smol window). What matters for the
      // AC: the calls happen at IDLE BOOT, before any user input exists.
      final callsAtBoot = stream.calls;
      expect(callsAtBoot, greaterThanOrEqualTo(1));

      io.sendLine('go');
      await waitForIt(
        () => stream.calls > callsAtBoot && !agent.isBusy,
        reason: 'the first user turn answers on the capped context',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('auto-compacted'));
      // The turn's request rides the CAPPED context: at/below the
      // compaction threshold (meter parity with the pre-cap number).
      final turnContext = stream.contexts.last;
      expect(requestTokensOf(turnContext), lessThanOrEqualTo(_threshold));
      // The cap genuinely folded: the kept messages the summary replaced
      // no longer ride the request.
      final texts = [
        for (final m in turnContext.messages)
          if (m is UserMessage) messageText(m),
      ];
      expect(texts.where((t) => t.startsWith('kept1 ')), isEmpty);
    },
  );

  test(
    'AC5: a dead summarizer at boot degrades to the local trim with a '
    'visible note — the boot survives and the next request is ≤ window',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedOverWindow('boot-cap-target');
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
      final agent = cli(env, stream);

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
      final env = await seedOverWindow('boot-cap-target');
      final stream = FakeStreamFunction([
        // The cap's summarizer SUCCEEDS and the transcript is restamped —
        // then rendering the report block throws (broken stdout). The
        // unexpected-throw class the on-Object backstop exists for.
        textTurn('compacted boot summary'),
        textTurn('answered after the crashed report'),
      ]);
      final brokenIo = _BrokenStdoutIo();
      final agent = AgentCli(
        config: AgentCliConfig(
          model: _model,
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
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'the turn proceeds after the crashed cap',
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
      expect(output, contains('answered after the crashed report'));
      // …on the CAPPED context (the transcript was restamped before the
      // report render crashed).
      expect(
        requestTokensOf(stream.contexts.last),
        lessThanOrEqualTo(_threshold),
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
      await seedOverWindow('boot-cap-target', into: env);

      // Turn 1 hangs until the interrupt cancels it (the Ctrl+C leg);
      // the boot cap's summarizer call after the switch consumes the
      // scripted turn.
      final cap = FakeStreamFunction([textTurn('compacted boot summary')]);
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
          model: _model,
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
      await waitForIt(
        () => !agent.isBusy,
        reason: 'the aborted turn settles',
      );
      expect(io.out.toString(), contains('Operation aborted'));

      // /resume switches to the newest session — the over-window one —
      // WITHOUT an intervening prompt run (the only place the stale flag
      // used to be cleared): the boot cap must still run, at idle, before
      // any user input.
      io.sendLine('/resume');
      await waitForIt(
        () => cap.calls >= 1 && !agent.isBusy,
        reason: 'the boot cap runs on the resumed (over-window) session '
            'despite the previous session\'s abort',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('auto-compacted'));
      // The resumed session's context was actually capped.
      expect(
        requestTokensOf(cap.contexts.single),
        lessThanOrEqualTo(_threshold),
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
