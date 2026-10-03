// Issue #1085 M2 — the over-window continuation funnel's round-1 review
// contract, over the scripted-LLM CLI harness (no network, no PTY):
//
// 1. the bounded retry is REAL: two compaction passes run and the
//    exhaustion verdict names them (the old single shot died quietly);
// 2. the verdict is HONEST: with compaction disabled it says zero passes
//    ran instead of blaming "N compaction attempts";
// 3. a user abort during the funnel's compaction stays an ABORT: the
//    engines report a cancelled summarizer as a failed pass, so the funnel
//    gates on the sticky abort flag + the token rethrow — no retry, no
//    resumed task, no false exhaustion verdict;
// 4. an auto-continued run that answers EMPTY gets the one-shot "continue"
//    nudge like any run (the old `!isAutoContinue` exclusion left the
//    continuation idle forever — the post-compaction silence again);
// 5. Ctrl+C during a BARE compaction (manual /compact, no run bracket)
//    stops the compaction while the session lives on — the round-2
//    review split: a run abort is run+compaction, a bare-compaction
//    interrupt is the compaction only (no sticky abort, no exit);
// 6. HEADLESS: the funnel's compaction runs outside any run bracket,
//    so its interrupt is compaction-only — but the FUNNEL must see the
//    cancel, not a "nothing changed" false (the round-4 blocker: the
//    swallowed cancel relaunched attempt 2). AutoCompactorFactory.run()
//    throws on cancel, the funnel rethrow is live, the task ends with
//    the loud interrupted-by-user error and no resumed task.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [StreamFunction] that plays [scripted] turns in order; from call
/// index [hangFromCall] on, every call HANGS until its cancel token fires
/// (the funnel's summarizer call, aborted by the user's Ctrl+C). The test
/// re-arms [hangFromCall] past the end once the abort is observed, so the
/// follow-up prompt's pre-flight compaction and answer can play out.
class ScriptedThenHangStream {
  ScriptedThenHangStream(this.scripted, {this.hangFromCall = 1 << 30});

  final List<List<AssistantMessageEvent>> scripted;
  var calls = 0;
  int hangFromCall;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final n = ++calls;
    final stream = AssistantMessageEventStream();
    if (n < hangFromCall || n > scripted.length) {
      for (final event in scripted[n - 1]) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
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
}

void main() {
  test(
    'exhaustion after two real compaction passes names them',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // Keep-recent covers the whole transcript: the classic pass runs but
      // frees nothing — the funnel burns both bounded passes and must land
      // the loud verdict naming exactly two passes.
      final fake = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('summary pass one'),
        textTurn('summary pass two'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 12000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 100000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final exitCode = await cli.runHeadless('count the words');
      await io.close();

      expect(exitCode, 1, reason: 'the task was NOT continued — loud failure');
      // Both bounded passes ran (guard + two summarizer calls)…
      expect(fake.calls, 3, reason: 'bounded retry: no third pass');
      // …and the verdict names what actually happened.
      final output = io.out.toString();
      expect(output, contains('error: the transcript is still'));
      expect(output, contains('2 compaction passes did not free it'));
      expect(output, contains('The task was NOT continued'));
      expect(output, isNot(contains('[resuming]')));
      expect(output, isNot(contains('compaction did not run')));
    },
  );

  test(
    'exhaustion with compaction disabled reports zero passes honestly',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      final fake = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 12000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionSettings: const CompactionSettings(
            enabled: false,
            reserveTokens: 100,
            keepRecentTokens: 100,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final exitCode = await cli.runHeadless('count the words');
      await io.close();

      expect(exitCode, 1);
      final output = io.out.toString();
      // The honest zero-pass verdict — the old wording claimed
      // "after 2 compaction attempts" with no attempt ever made.
      expect(output, contains('compaction did not run'));
      expect(output, contains('The task was NOT continued'));
      expect(output, isNot(contains('compaction attempts did not free it')));
    },
  );

  test(
    'a user abort during the hung over-window retry stays an abort: '
    'no relaunch, no resumed task, no false verdict',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const window32k = Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 32768,
        maxTokens: 4096,
      );
      final shell = FakeShell(stdout: 'x' * 32800);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final io = FakeCliIO();
      // Call 1: the ballooning tool turn; the guard refuses the retried
      // request. Call 2: the loop's mid-run relief pass — frees nothing,
      // so the relief's local trim frees the window and the loop RETRIES
      // the request: call 3. The retry HANGS until the user aborts — the
      // interrupt must cancel the in-flight call, surface loudly, and
      // never relaunch it.
      final fake = ScriptedThenHangStream([
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: const {'command': 'cat a.log'},
          ),
          ToolCall(
            id: 'c2',
            name: 'bash',
            arguments: const {'command': 'cat b.log'},
          ),
          ToolCall(
            id: 'c3',
            name: 'bash',
            arguments: const {'command': 'cat c.log'},
          ),
        ]),
        // Relief pass — frees nothing (keep floor pins the transcript
        // over the window), so the funnel takes over.
        textTurn('S'),
        // The funnel's compaction summarizer — hangs from here on.
        textTurn('S'),
        // A would-be retry pass — must NEVER run after the abort.
        textTurn('S'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
          // A keep-recent floor above the window: the relief's local-trim
          // valve cannot free the window, so the funnel's compaction pass is
          // the only thing running when the user aborts.
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 40000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 3,
        reason: 'the funnel compaction started',
      );
      io.interrupt();
      await waitForIt(
        () => io.out.toString().contains('interrupted by user'),
        reason: 'the abort surfaces as an error line',
      );
      // No retry after the abort: give a would-be second pass ample time to
      // start, then pin the call count.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 3, reason: 'the aborted compaction is not relaunched');

      final output = io.out.toString();
      expect(output, isNot(contains('[resuming]')));
      expect(output, isNot(contains('The task was NOT continued')));
      expect(output, isNot(contains('auto-compacted; continuing')));

      // The REPL loop returned to idle (the settle path completed instead
      // of hanging on the cancelled compaction).
      expect(output, contains('turn 2'));

      io.sendLine('/exit');
      await run;
      await io.close();
    },
  );

  test(
    'an auto-continued run that answers empty gets the continue nudge',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const window32k = Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 32768,
        maxTokens: 4096,
      );
      final shell = FakeShell(stdout: 'x' * 32800);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final io = FakeCliIO();
      final emptyTurn = [
        DoneEvent(reason: StopReason.stop, message: testAssistant()),
      ];
      final fake = FakeStreamFunction([
        // The ballooning tool turn; the guard refuses the retried request.
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: const {'command': 'cat a.log'},
          ),
          ToolCall(
            id: 'c2',
            name: 'bash',
            arguments: const {'command': 'cat b.log'},
          ),
          ToolCall(
            id: 'c3',
            name: 'bash',
            arguments: const {'command': 'cat c.log'},
          ),
        ]),
        // Consumed by the loop's mid-run relief pass — frees nothing.
        textTurn('S'),
        // Consumed by the funnel's compaction — frees the window.
        textTurn('S'),
        // The auto-continued run answers EMPTY: nothing actionable.
        emptyTurn,
        // Only reachable when the nudge fired on the auto-continued run.
        textTurn('nudged continuation fine'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 5 && !cli.isBusy,
        reason: 'empty auto-continued reply nudged to a real answer',
      );
      io.sendLine('/exit');
      await run;
      await io.close();

      final output = io.out.toString();
      expect(output, contains('[resuming]'));
      expect(output, contains('nudged continuation fine'));
      expect(fake.calls, 5, reason: 'tool, relief, funnel fold, empty, nudge');
      // The fifth request is the NUDGE ('continue'), not the original user
      // text — the M2b contract: auto-continued runs get the nudge like any
      // run; the old exclusion stopped at the empty reply and went silent.
      final nudgePrompt = fake.contexts[4].messages
          .whereType<UserMessage>()
          .last;
      expect(nudgePrompt.content as String, 'continue');
    },
  );

  test(
    'Ctrl+C during a bare /compact stops the compaction, keeps the session',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // Window wide enough that ordinary turns never trip the compaction
      // threshold — the ONLY compaction here is the manual /compact. The
      // keep-recent floor is small, so the pass really calls a summarizer.
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('first answer'),
        textTurn('resummarized context'),
        textTurn('second answer'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'wide-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 32768,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 2000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 2 && !cli.isBusy,
        reason: 'turn 1 completed',
      );
      io.sendLine('/compact');
      await waitForIt(
        () => fake.calls >= 3,
        reason: 'the manual compaction summarizer started',
      );
      io.interrupt();
      await waitForIt(
        () => io.out.toString().contains('compaction interrupted'),
        reason: 'the compaction-only interrupt prints its dim receipt',
      );
      fake.hangFromCall = 1 << 30; // re-arm: the follow-up turn must play out

      io.sendLine('again');
      await waitForIt(
        () => fake.calls >= 4 && !cli.isBusy,
        reason: 'the session survived: the next prompt runs normally',
      );
      final output = io.out.toString();
      // No run-abort side effects leaked into the bare-compaction window:
      // no error line, no fake verdict — and the next turn really ran.
      expect(output, isNot(contains('error:')));
      expect(output, isNot(contains('The task was NOT continued')));
      expect(output, contains('second answer'));

      io.sendLine('/exit');
      await run;
      await io.close();
    },
  );
  test(
    'Ctrl+C during the post-run compaction prints the dim receipt, no spurious error line',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // The window is sized so ordinary turns NEVER trip the guard
      // (~21k-token transcript vs a 32768 window), but the compaction
      // threshold sits BETWEEN the trimmed (9.4k) and the finished-turn
      // (20.9k) transcript sizes (32768 - 20768 = 12000) — so _afterRun's
      // post-run compaction fires right after turn 1 and call 3 is its
      // hung summarizer. The interrupt must surface as the dim receipt
      // ONLY: the round-4 `_afterRun` swallow (issue #1085 review) keeps
      // the CancelledException from re-entering error handling over an
      // already-settled turn — even though the pass's trim fallback
      // "succeeded" (a success racing a late cancel is equally dead).
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('first answer'),
        textTurn('unused — call 3 is the cancelled post-run summarizer'),
        textTurn('second answer'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'post-run-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 32768,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 20768,
            keepRecentTokens: 2000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 3,
        reason: 'turn 1 completed and the post-run compaction started',
      );
      io.interrupt();
      await waitForIt(
        () => io.out.toString().contains('compaction interrupted'),
        reason: 'the post-run compaction interrupt prints its dim receipt',
      );
      fake.hangFromCall = 1 << 30; // re-arm: the follow-up turn must play out

      // The next prompt runs normally: the trimmed transcript (9.4k) sits
      // under the 12k threshold, so no pre-flight compaction fires and
      // turn 2's request is call 4 (call 3 was the cancelled hang).
      io.sendLine('again');
      await waitForIt(
        () => fake.calls >= 4 && !cli.isBusy,
        reason: 'the session survived: the next prompt runs normally',
      );
      final output = io.out.toString();
      expect(output, contains('first answer'));
      expect(output, contains('compaction interrupted'));
      // The swallow's whole point: the CancelledException never re-enters
      // error handling — no spurious `error:` line over the settled turn.
      expect(output, isNot(contains('error:')));
      expect(output, isNot(contains('CancelledException')));
      expect(output, isNot(contains('The task was NOT continued')));
      expect(output, isNot(contains('[resuming]')));
      expect(output, contains('second answer'));

      io.sendLine('/exit');
      await run;
      await io.close();
    },
  );

  test(
    'headless: Ctrl+C during the in-loop relief aborts the run, no relaunch',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // Call 2 is the over-window relief's summarizer, running INSIDE the
      // live agent run. The interrupt must cancel it and end the run as an
      // abort — never a relaunch of the pass and never the guard error
      // (which would hand the task to the continuation funnel).
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('unused — call 2 is the hung relief summarizer'),
      ], hangFromCall: 2);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 12000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 40000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final run = cli.runHeadless('count the words');
      await waitForIt(
        () => fake.calls >= 2,
        reason: 'the relief compaction summarizer started',
      );
      io.interrupt();
      final exitCode = await run;
      // No attempt-2 relaunch after the cancel: give it ample time, then
      // pin the call count.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 2, reason: 'the pass is never relaunched');

      final output = io.out.toString();
      // The relief abort ends the run: headless SIGINT parity is exit 130
      // (runHeadless maps StopReason.aborted to 130) — a user-intended
      // stop, not silence and not a fake success.
      expect(
        exitCode,
        130,
        reason: 'the abort surfaces as the headless abort exit code',
      );
      // The relief abort never reaches the funnel: no dim receipt, no
      // exhaustion verdict, no resumed marker.
      expect(output, isNot(contains('compaction interrupted')));
      expect(output, isNot(contains('The task was NOT continued')));
      expect(output, isNot(contains('[resuming]')));
      await io.close();
    },
  );

  test(
    'headless: Ctrl+C during the settle-funnel compaction aborts loudly, no relaunch',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // Headless settles OUTSIDE any run bracket, so the funnel's
      // compaction cancel is compaction-only — and the funnel must still
      // SEE the cancel and rethrow it loudly. Call 2 is the one-shot
      // in-loop relief (completes, but keepRecentTokens keeps everything,
      // so it frees nothing and the guard stops the turn with the
      // exhausted error); call 3 is the settle funnel's compaction, hung
      // when the interrupt lands. Before the fix the funnel swallowed that
      // cancel as "compaction interrupted" and RELAUNCHED the pass as
      // attempt 2 (call 4) — the silence-with-spinner bug.
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('relief pass summary that frees nothing'),
        textTurn('attempt-2 relaunch probe — must never be consumed'),
      ], hangFromCall: 3);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 12000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 40000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final run = cli.runHeadless('count the words');
      await waitForIt(
        () => fake.calls >= 3,
        reason: 'the funnel compaction summarizer started',
      );
      io.interrupt();
      final exitCode = await run;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 3, reason: 'no attempt-2 relaunch after the cancel');

      final output = io.out.toString();
      // The cancel surfaces as the loud abort through the run's error
      // handling — exit 1 with the real reason on the transcript.
      expect(
        exitCode,
        1,
        reason: 'the cancel surfaces as a loud abort via the error line',
      );
      expect(output, contains('interrupted by user'));
      // Not the bare-window dim receipt and not the exhaustion verdict.
      expect(output, isNot(contains('compaction interrupted')));
      expect(output, isNot(contains('The task was NOT continued')));
      expect(output, isNot(contains('[resuming]')));
      await io.close();
    },
  );
}
