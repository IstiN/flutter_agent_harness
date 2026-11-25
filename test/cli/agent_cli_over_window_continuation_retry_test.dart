// gh-209 — the two-tier compaction engine's over-window paths, over the
// scripted-LLM CLI harness (no network, no PTY).
//
// The mid-turn relief runs ONLY the deterministic emergency tier now (no
// LM call on any path). The funnel (the bounded classic/structured retry
// from issue #1085 M2) survives as the BACKSTOP for the shape the
// deterministic tier cannot free, and its review contract still holds:
//
// 1. the deterministic relief recovers a ballooned transcript in ONE
//    pass — seconds, zero summarizer calls; the dedup pass folds the
//    older copy of a re-read path (lossless append) and the trim valve
//    bounds the live context in memory;
// 2. the funnel backstop: when the relief cannot free the window (the
//    keep floor pins the valve below the newest message), the bounded
//    passes run and the local trim still recovers the task;
// 3. with compaction disabled the verdict says zero passes ran instead
//    of blaming "N compaction attempts";
// 4. a user abort during the funnel's compaction stays an ABORT: no
//    retry, no resumed task, no false exhaustion verdict;
// 5. an auto-continued run that answers EMPTY gets the one-shot
//    "continue" nudge like any run (the post-compaction silence rule);
// 6. Ctrl+C during a BARE compaction (manual /compact, no run bracket)
//    stops the compaction while the session lives on — a run abort is
//    run+compaction, a bare-compaction interrupt is the compaction only;
// 7. HEADLESS: the funnel's compaction runs outside any run bracket, so
//    its interrupt is compaction-only — but the FUNNEL must see the
//    cancel, not a "nothing changed" false (the round-4 blocker: the
//    swallowed cancel relaunched attempt 2). AutoCompactorFactory.run()
//    throws on cancel, the funnel rethrow is live, the task ends with
//    the loud interrupted-by-user error and no resumed task.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    'the emergency relief recovers deterministically: no summarizer call',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      env.writeFile('mid.txt', List.filled(500, 'y' * 40).join('\n'));
      env.writeFile('big2.txt', List.filled(1000, 'z' * 45).join('\n'));
      final io = FakeCliIO();
      // Three reads over a tiny window: the deterministic relief (the
      // in-memory trim valve — the keep-N fold stays inside the protected
      // tail on this small transcript) bounds the live context after
      // every over-window measure. No summarizer call ever runs; the
      // session file keeps every original record (the valve is
      // in-memory only).
      final fake = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        toolTurn([
          const ToolCall(
            id: 't2',
            name: 'read',
            arguments: {'path': 'mid.txt'},
          ),
        ]),
        toolTurn([
          const ToolCall(
            id: 't3',
            name: 'read',
            arguments: {'path': 'big2.txt'},
          ),
        ]),
        textTurn('continuing after the relief'),
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
          apiKey: '[REDACTED:Sensitive-Value]',
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

      expect(exitCode, 0, reason: 'the task continued on the relieved context');
      // Deterministic: three tool turns + the retried request. No
      // summarizer call ever ran.
      expect(fake.calls, 4, reason: 'relief then retry — zero LM compaction');
      final output = io.out.toString();
      // The relieved turn continues visibly.
      expect(output, contains('[resuming]'));
      // The loud terminal verdict is GONE: the task was continued.
      expect(output, isNot(contains('did not free it')));
      expect(output, isNot(contains('The task was NOT continued')));

      // In-memory relief: no compaction-side records at all — the
      // session file keeps every original record untouched (gh-209 owner
      // directive: additive only).
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      final session = await repo.open(sessions.first);
      final entries = await session.getEntries();
      expect(
        entries.whereType<CompactionRecord>(),
        isEmpty,
        reason: 'the relief appended no compaction record',
      );
      expect(entries.whereType<HiddenRangeRecord>(), isEmpty);
      final carriers = entries
          .whereType<MessageRecord>()
          .map((r) => r.message)
          .whereType<AssistantMessage>()
          .where((m) => m.content.whereType<ToolCall>().isNotEmpty)
          .length;
      expect(carriers, 3, reason: 'every original record stays in the file');
    },
  );

  test(
    'the funnel backstop: a keep floor the relief cannot cross still '
    'recovers through its bounded pass',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // The keep-recent floor (400) sits BELOW the newest message: the
      // deterministic relief's valve finds nothing droppable (its budget
      // is capped by keepRecentTokens), so it declines — and the FUNNEL
      // backstop takes over: the bounded classic pass runs, frees the
      // window, and the interrupted task continues on the compacted
      // transcript (the issue #1085 M2 recovery, preserved verbatim
      // behind the new tier).
      final fake = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('summary pass one'),
        textTurn('continuing the task after the trim'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            // + the gh-2423 working-set surface (gh2423ContextIncludesTokens).
            contextWindow: 12000 + gh2423ContextIncludesTokens,
            maxTokens: 4096,
          ),
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 400,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final exitCode = await cli.runHeadless('count the words');
      await io.close();

      expect(
        exitCode,
        0,
        reason: 'the task continued on the compacted context',
      );
      // Tool turn + the funnel's bounded pass + the continuation.
      expect(fake.calls, 3, reason: 'bounded retry: no third LM compaction');
      final output = io.out.toString();
      // The funnel recovered the task visibly…
      expect(output, contains('auto-compacted; continuing the turn'));
      expect(output, contains('[resuming]'));
      // …and the loud terminal verdict is GONE.
      expect(output, isNot(contains('did not free it')));
      expect(output, isNot(contains('The task was NOT continued')));
    },
  );

  test(
    'a huge prompt over a tiny window still recovers (issue #1914)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final io = FakeCliIO();
      // One huge prompt over a tiny window: the deterministic relief's
      // hide passes have nothing to fold and the valve cannot drop the
      // newest (and only) message, so the funnel backstop takes over. The
      // first pass keeps everything (the never-crossing backward walk)
      // and the retry must NOT repeat the identical cut — it escalates
      // past the previous kept boundary. The weight rides the newest
      // (tail) messages, which a prefix fold cannot drop, so the
      // mechanical local trim bounds the context and the task continues —
      // no terminal abort.
      final fake = FakeStreamFunction([
        textTurn('summary pass one'),
        textTurn('summary pass two'),
        textTurn('spare — the recovery lands on an earlier slot'),
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
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 400,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final exitCode = await cli.runHeadless('x' * 50000);
      await io.close();

      expect(exitCode, 0, reason: 'the task continued on the trimmed context');
      expect(fake.calls, 2, reason: 'one bounded pass, then the continuation');
      final output = io.out.toString();
      expect(output, contains('[context trimmed]'));
      expect(output, isNot(contains('did not free it')));
      expect(output, isNot(contains('The task was NOT continued')));
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
      // Compaction is disabled AND the keep floor pins the whole
      // transcript: the deterministic relief's valve has nothing
      // droppable (its budget is capped by keepRecentTokens), the funnel
      // runs ZERO passes, and the exhaustion verdict says exactly that.
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
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionSettings: const CompactionSettings(
            enabled: false,
            reserveTokens: 100,
            keepRecentTokens: 400,
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
    'a user abort during the hung funnel backstop stays an abort: '
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
      // request. The deterministic relief runs first — instant, no LM
      // (the keep floor pins its valve below the newest result, so it
      // frees nothing) — then the funnel's compaction summarizer
      // (call 2) HANGS until the user aborts. The interrupt must cancel
      // the in-flight call, surface loudly, and never relaunch it.
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
        // The funnel's compaction summarizer — hangs from here on.
        textTurn('S'),
        // A would-be retry pass — must NEVER run after the abort.
        textTurn('S'),
      ], hangFromCall: 2);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
          // A keep-recent floor below the newest result: the deterministic
          // relief's valve cannot free the window either, so the funnel's
          // compaction pass is the only thing running when the user
          // aborts.
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 400,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 2,
        reason: 'the funnel compaction started',
      );
      io.interrupt();
      await io.out.waitUntilContains(
        'interrupted by user',
        reason: 'the abort surfaces as an error line',
      );
      // No retry after the abort: give a would-be second pass ample time to
      // start, then pin the call count.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 2, reason: 'the aborted compaction is not relaunched');

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
        // Consumed by the funnel's bounded pass (the deterministic relief
        // declines — the keep floor pins its valve).
        textTurn('S'),
        // The auto-continued run answers EMPTY: nothing actionable.
        emptyTurn,
        // Only reachable when the nudge fired on the auto-continued run.
        textTurn('nudged continuation fine'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 400,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );
      final run = cli.run();

      io.sendLine('go');
      await waitForIt(
        () => fake.calls >= 4 && !cli.isBusy,
        reason: 'empty auto-continued reply nudged to a real answer',
      );
      io.sendLine('/exit');
      await run;
      await io.close();

      final output = io.out.toString();
      expect(output, contains('[resuming]'));
      expect(output, contains('nudged continuation fine'));
      expect(fake.calls, 4, reason: 'tool, funnel pass, empty, nudge');
      // The fourth request is the NUDGE ('continue'), not the original
      // user text — the M2b contract: auto-continued runs get the nudge
      // like any run; the old exclusion stopped at the empty reply and
      // went silent.
      final nudgePrompt = fake.contexts[3].messages
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
          apiKey: '[REDACTED:Sensitive-Value]',
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
      await io.out.waitUntilContains(
        'compaction interrupted',
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
      // already-settled turn. Issue #2263: the interrupted compaction no
      // longer TRIMS (an abort is never answered with the local trim), so
      // the transcript stays over threshold and the NEXT turn's
      // pre-flight compaction legitimately fires — call 4 is its
      // summarizer, call 5 the turn itself.
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
        textTurn(
          'pre-flight summary — call 4 is turn 2\'s pre-flight '
          'compaction',
        ),
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
          apiKey: '[REDACTED:Sensitive-Value]',
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
      await io.out.waitUntilContains(
        'compaction interrupted',
        reason: 'the post-run compaction interrupt prints its dim receipt',
      );
      fake.hangFromCall = 1 << 30; // re-arm: the follow-up turn must play out

      // The next prompt runs normally: the transcript is still over the
      // 12k threshold (no trim on the aborted run — issue #2263), so
      // turn 2's PRE-FLIGHT compaction fires first (call 4, its
      // summarizer) and the turn's request is call 5.
      io.sendLine('again');
      await waitForIt(
        () => fake.calls >= 5 && !cli.isBusy,
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
    'headless: Ctrl+C during the funnel-recovered retry aborts the run, '
    'no relaunch',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
      final io = FakeCliIO();
      // Call 2 is the funnel's bounded pass (the deterministic relief
      // declines — the keep floor pins its valve); the pass FREES the
      // window (the 11000-token floor still allows a fold) and the funnel
      // relaunches the task. Call 3 is the RETRIED request, hung. The
      // interrupt must cancel it and end the run as an abort — never a
      // relaunch and never the guard error.
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('summary pass one'),
        textTurn('unused — call 3 is the hung retried request'),
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
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 11000,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final run = cli.runHeadless('count the words');
      await waitForIt(
        () => fake.calls >= 3,
        reason: 'the retried request started after the funnel recovered',
      );
      io.interrupt();
      final exitCode = await run;
      // No attempt-2 relaunch after the cancel: give it ample time, then
      // pin the call count.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 3, reason: 'the retry is never relaunched');

      final output = io.out.toString();
      // The retry abort ends the run: headless SIGINT parity is exit 130
      // (runHeadless maps StopReason.aborted to 130) — a user-intended
      // stop, not silence and not a fake success.
      expect(
        exitCode,
        130,
        reason: 'the abort surfaces as the headless abort exit code',
      );
      // The retry abort never reaches the funnel: no dim receipt, no
      // exhaustion verdict, no resumed marker.
      expect(output, isNot(contains('compaction interrupted')));
      expect(output, isNot(contains('The task was NOT continued')));
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
      // SEE the cancel and rethrow it loudly. The deterministic relief
      // runs first (instant, no LM — the keep floor pins everything, so
      // it frees nothing) and the guard stops the run with the exhausted
      // error; call 2 is the settle funnel's compaction, hung when the
      // interrupt lands. Before the fix the funnel swallowed that cancel
      // as "compaction interrupted" and RELAUNCHED the pass as attempt 2
      // (call 3) — the silence-with-spinner bug.
      final fake = ScriptedThenHangStream([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'big.txt'},
          ),
        ]),
        textTurn('attempt-2 relaunch probe — must never be consumed'),
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
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 400,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final run = cli.runHeadless('count the words');
      await waitForIt(
        () => fake.calls >= 2,
        reason: 'the funnel compaction summarizer started',
      );
      io.interrupt();
      final exitCode = await run;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(fake.calls, 2, reason: 'no attempt-2 relaunch after the cancel');

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
      await io.close();
    },
  );

  test(
    'a run that relieves BOTH dimensions succeeds: no second pass, no '
    'local trim, no false still-over message (issue #2264)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      // The refusal shape: a moderately large real-user prompt (~6.8k
      // tokens — real user turns never hide, F8) plus growing read
      // results (500·i tokens, DISTINCT paths so the dedup has nothing
      // to fold). With the request-size overhead on top, the first three
      // requests stay under the trigger and the fourth/fifth go over it,
      // where the relief's keep-2 hide budget cannot free the overage and
      // its valve declines (every result exceeds the 200-token keep
      // budget) — so the window guard REFUSES with BOTH dimensions over:
      // tokens > window AND count ≥ cap − margin.
      for (var i = 1; i <= 5; i++) {
        env.writeFile('note$i.txt', List.filled(100 * i, 'x' * 20).join('\n'));
      }
      final home = await Directory.systemTemp.createTemp('fa_2264_');
      // A learned cap (24 → trigger at count ≥ 8) the way a previous
      // process left it: the PRE-RUN gate snapshot is over on BOTH
      // dimensions when the funnel fires.
      Directory('${home.path}/.fah').createSync(recursive: true);
      File('${home.path}/.fah/model_caps.json').writeAsStringSync(
        jsonEncode({
          ModelCapsStore.keyOf('test-provider', 'tiny-window'): {
            'maxMessages': 24,
          },
        }),
      );
      final io = FakeCliIO();
      // The funnel's classic pass lands both dimensions under — and the
      // success criterion must judge that from the POST-RUN measurements,
      // not the stale pre-run overCap snapshot (issue #2264: the stale
      // true used to fail the check, the second attempt no-oped, and the
      // gh-1914 valve / exhaustion verdict fired on a now-HEALTHY
      // transcript with a false "still ~N tokens vs the W-token window"
      // line at N < W).
      final fake = FakeStreamFunction([
        for (var i = 1; i <= 5; i++)
          toolTurn([
            ToolCall(
              id: 't$i',
              name: 'read',
              arguments: {'path': 'note$i.txt'},
            ),
          ]),
        textTurn('summary pass one'),
        textTurn('continuing the task after the compact'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            // + the gh-2423 working-set surface (gh2423ContextIncludesTokens).
            contextWindow: 20000 + gh2423ContextIncludesTokens,
            maxTokens: 4096,
          ),
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          homeDir: home.path,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionEngine: CompactionEngine.classic,
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 100,
            keepRecentTokens: 200,
          ),
        ),
        io: io,
        streamFunction: fake.call,
      );

      final exitCode = await cli.runHeadless('count the words ${'x' * 27200}');
      await io.close();
      home.deleteSync(recursive: true);

      // Poisoned-run sanity: the guard refused LATE enough that the
      // message-count dimension was over the learned-cap trigger. The
      // poisoned minimum is a refusal at read 4 (count 9 ≥ cap − margin
      // 8): 4 reads + the summarizer pass + the continuation. A collapsed
      // scenario — an early refusal under the cap trigger (≤ 5 calls), or
      // a run that never reached the funnel — fails here instead of
      // guarding nothing.
      expect(
        fake.calls,
        greaterThanOrEqualTo(6),
        reason:
            'the refusal must land at read 4 or later (count ≥ cap − '
            'margin), with the summarizer pass and the continuation behind '
            'it',
      );
      // The relieved run IS a success: the funnel took the success
      // branch and continued the interrupted task.
      expect(exitCode, 0, reason: 'the relieved run continues the task');
      final output = io.out.toString();
      expect(output, contains('auto-compacted; continuing the turn'));
      expect(output, contains('[resuming] continuing the interrupted task'));
      // No second pass, no local trim of the now-HEALTHY transcript, and
      // no false "still ~N tokens vs the W-token window" line (N < W).
      expect(output, isNot(contains('[context trimmed]')));
      expect(output, isNot(contains('still ~')));
      expect(output, isNot(contains('did not free it')));
      expect(output, isNot(contains('The task was NOT continued')));
      // The continuation rode the COMPACTED transcript, not a re-trimmed
      // copy: no [context trimmed locally] valve marker anywhere.
      for (final message in fake.contexts.last.messages) {
        final text = message is UserMessage ? messageText(message) : '';
        expect(text, isNot(contains('context trimmed locally')));
      }
    },
  );

  group('overWindowReliefVerdict decision table (issue #2264)', () {
    // (afterTokens, window, capTriggered, passesRan, expected)
    const cases = <(int, int, bool, int, OverWindowReliefVerdict)>[
      // Relieved BOTH dimensions: a success — no second pass, no trim.
      (11000, 20000, false, 1, OverWindowReliefVerdict.success),
      // `window` itself FITS (the criterion is `<=`).
      (20000, 20000, false, 1, OverWindowReliefVerdict.success),
      // Fits the window but the learned-cap trigger still fires: legal
      // request, no valve, continue truthfully.
      (11000, 20000, true, 1, OverWindowReliefVerdict.continueUnderWindow),
      // Still over the window after a pass: the trim valve applies —
      // whatever the count dimension says.
      (25000, 20000, false, 1, OverWindowReliefVerdict.trimValve),
      (25000, 20000, true, 1, OverWindowReliefVerdict.trimValve),
      // Zero passes: the honest exhausted verdict stands, regardless of
      // the measurements (a disabled/refused config).
      (25000, 20000, false, 0, OverWindowReliefVerdict.exhausted),
      (11000, 20000, false, 0, OverWindowReliefVerdict.exhausted),
      (11000, 20000, true, 0, OverWindowReliefVerdict.exhausted),
    ];
    for (final (tokens, window, triggered, passes, expected) in cases) {
      test('tokens=$tokens window=$window capTriggered=$triggered '
          'passes=$passes -> ${expected.name}', () {
        expect(
          overWindowReliefVerdict(
            afterTokens: tokens,
            window: window,
            messageCapTriggered: triggered,
            passesRan: passes,
          ),
          expected,
        );
      });
    }

    test('the funnel receipts pluralize honestly', () {
      expect(compactionPassesLabel(1), 'pass');
      expect(compactionPassesLabel(2), 'passes');
      expect(compactionPassesLabel(0), 'passes');
    });
  });
}
