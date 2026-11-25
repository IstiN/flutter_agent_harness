import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #413: a headless run whose context window is exhausted MID-TURN
/// must auto-compact and continue the interrupted task — the REPL has done
/// exactly that since the over-window continuation landed, but headless
/// ended the whole run on the guard stop, abandoning the task. The exit
/// code must also describe the turn's terminal outcome: post-run
/// compaction rebuilds the visible transcript (the checkpoint fold drops
/// the assistant turns entirely), and reading `state.messages` after it
/// masked failed runs as exit 0.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late TransientRetryNotice? savedNotice;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    savedNotice = transientRetryNotice;
    // The overflow payload: a real tool result the `read` tool returns in
    // full (short lines stay under its line cap; ~46k chars ≈ 11.5k
    // estimated tokens) — not a split assistant turn, so the classic
    // prefix compaction hides it cleanly.
    env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
  });

  tearDown(() {
    // `runHeadless` wires the global [net] notice (issue #1121) — never
    // leak it into other suites.
    transientRetryNotice = savedNotice;
    io.close();
  });

  // 12k window: with the gh-2411 fixture seam (`tinyPrompt` +
  // `tinyTools`) the fixed request overhead is ~3.4k estimated tokens, so
  // request 1 still fits while the ~11.5k-token tool result overflows
  // request 2 — the guard fires MID-TURN, not before the first request.
  // (With the real CLI prompt the overhead alone — ~14.4k tokens — is the
  // soft-window regime: the guard stands down by design.)
  AgentCli buildCli(
    FakeStreamFunction stream, {
    CompactionEngine? engine,
    CompactionSettings? settings,
    int window = 12000,
  }) => AgentCli(
    config: AgentCliConfig(
      // gh-2411: overflow through messages, not overhead.
      systemPrompt: tinyPrompt,
      runtimeTools: tinyTools(const ['read', 'bash']),
      // Non-const: the window is the test's (gh-2411 follow-up).
      model: Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: window,
        maxTokens: 4096,
      ),
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionEngine: engine,
      compactionSettings: settings,
    ),
    io: io,
    streamFunction: stream.call,
  );

  /// One turn delegating to `read big.txt`: the executed tool result (not
  /// the assistant message) carries the ~25k estimated tokens, so request
  /// 2 overflows and the guard refuses it.
  List<AssistantMessageEvent> bigReadTurn() => toolTurn([
    const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
  ]);

  test(
    'headless over-window stop compacts and continues the turn',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // Request 1 delegates to `read big.txt` → the executed result carries
      // ~11.5k tokens → the loop's guard refuses request 2. Since gh-209
      // the mid-turn relief is the deterministic emergency tier — it
      // attempts NO language-model call (the single read group stays
      // inside its keep budget and the valve floor pins below the newest
      // message, so it frees nothing here) → the guard stop lands. The
      // settle path (a turn boundary) owns the quality tier: its
      // compaction (call 2) hides the tool result and frees the window →
      // the continuation turn (call 3) finishes the task.
      final stream = FakeStreamFunction([
        bigReadTurn(),
        textTurn('summary of the compacted history'),
        textTurn('task complete: all files counted'),
        textTurn('done after resume'),
      ]);
      final cli = buildCli(
        stream,
        engine: CompactionEngine.classic,
        // Tiny keep region: the big tool result must fall OUTSIDE it, so
        // the classic prefix compaction has something to summarize away
        // (pi's fixed keep-20k default would cover the whole ~20k
        // transcript and free nothing).
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 100,
        ),
      );

      final exitCode = await cli.runHeadless('count the words');

      // Guard stop → the deterministic relief (zero LM calls mid-turn) →
      // settle-path compaction (call 2, frees the window) → continuation
      // turn (call 3): the task DROVE TO COMPLETION.
      expect(exitCode, 0, reason: 'the continued turn finished normally');
      expect(
        stream.calls,
        3,
        reason:
            'guard refused request 2; the mid-turn relief is '
            'deterministic (no LM), so only the settle-path compaction '
            'and the continuation follow',
      );
      // The continuation is the notice prompt, not a bare retry of the
      // original user text.
      final lastPrompt = stream.contexts[2].messages
          .whereType<UserMessage>()
          .last;
      expect(
        lastPrompt.content as String,
        contains('Continue the interrupted task'),
      );
    },
  );

  test(
    'headless guard stop without freed window exits 1, not masked 0',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // The field variant of issue #413 (0.1.357 CI runs): the guard
      // stops the turn and compaction frees nothing. The run MUST read
      // as a failure (exit 1) whatever compaction does to the visible
      // transcript afterwards — `state.messages.lastOrNull` used to
      // answer exit 0 here. Compaction is disabled outright for a
      // deterministic "could not free" path.
      final stream = FakeStreamFunction([
        bigReadTurn(),
        textTurn('summary of the compacted history'),
      ]);
      final cli = buildCli(
        stream,
        settings: const CompactionSettings(
          enabled: false,
          reserveTokens: 100,
          keepRecentTokens: 100,
        ),
      );

      final exitCode = await cli.runHeadless('count the words');

      expect(exitCode, 1, reason: 'the guard stop is a failed run');
      expect(
        io.out.toString(),
        contains('compaction did not run'),
        reason: 'the settle path ran: the note follows the compact attempt',
      );
      expect(
        io.out.toString(),
        contains('The task was NOT continued'),
        reason: 'the loud terminal verdict names the stopped task',
      );
    },
  );

  test(
    'scope-2 B (gh-241 review): the guard stop prints ONE visible warning '
    'per session, however many times the guard trips',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      // ONE run, TWO over-window stops — the first test's scenario
      // twice: turn 1 reads big.txt (the result overflows the request →
      // guard stop → settle compaction → continuation), and the
      // continuation reads big.txt AGAIN (a second guard stop). The
      // continuation retry is ONE per run, so the second stop is the
      // terminal one (exit 1) — the latch is what keeps it from warning
      // a second time.
      final stream = FakeStreamFunction([
        bigReadTurn(),
        textTurn('summary of the compacted history'),
        bigReadTurn(),
        textTurn('summary of the second compaction'),
        textTurn('task complete: all files counted'),
      ]);
      final cli = buildCli(
        stream,
        engine: CompactionEngine.classic,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 100,
        ),
      );

      final exitCode = await cli.runHeadless('count the words');

      final output = io.out.toString();
      final stops = output
          .split('\n')
          .where((line) => line.contains('Context window exhausted'))
          .toList();
      expect(
        stops,
        hasLength(2),
        reason:
            'precondition: the guard tripped TWICE in the session; '
            'calls=${stream.calls} output:\n$output',
      );
      final warnings = output
          .split('\n')
          .where((line) => line.contains('request exceeded the window'))
          .toList();
      expect(
        warnings,
        hasLength(1),
        reason:
            'one visible warning per session — the second guard stop must '
            'stay silent; calls=${stream.calls} output:\n$output',
      );
      expect(warnings.single, contains('auto-compacting'));
      expect(
        stream.calls,
        5,
        reason:
            'both stops ran their relief: read, compaction, read, '
            'compaction, then the terminal stop',
      );
      // The second stop exhausts the run's single continuation retry —
      // the existing contract (never a masked 0).
      expect(exitCode, 1);
    },
  );

  test(
    'gh-2411 + owner live test: in the soft-window regime the hide-only '
    'pass runs at the window — the old tool result is hidden, the newest '
    'user turn rides verbatim, and an under-window prompt is left alone',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      // Window 13k, reserve 3250 → trigger 9750. The ~3.4k fixed overhead
      // plus a ~7.4k-token prompt is over the trigger (the regime — no
      // trim could ever reach it) while request 1 (~10.9k) is still UNDER
      // the window: nothing is trimmed, the request goes as is (ONE
      // warning). Two tool results later the request is over the window:
      // the LM-free emergency relief runs INSTEAD of a skip (the mid-turn
      // hide pass keeps both recent reads; the settle relief's local trim
      // valve then frees the window) — the prompt is carried verbatim
      // and the turn completes under the window.
      env.writeFile('old.txt', List.filled(120, 'o' * 40).join('\n'));
      env.writeFile('new.txt', List.filled(120, 'n' * 40).join('\n'));
      final prompt =
          'Count the words in old.txt and new.txt, then answer. '
          '${'question ' * 3300}';
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'read',
            arguments: {'path': 'old.txt'},
          ),
        ]),
        toolTurn([
          const ToolCall(
            id: 't2',
            name: 'read',
            arguments: {'path': 'new.txt'},
          ),
        ]),
        textTurn('done: both files counted'),
      ]);
      final cli = buildCli(
        stream,
        engine: CompactionEngine.classic,
        window: 13000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 3250,
          keepRecentTokens: 100,
        ),
      );

      final exitCode = await cli.runHeadless(prompt);
      expect(exitCode, 0, reason: 'calls=${stream.calls}\n${io.out}');
      expect(
        stream.calls,
        3,
        reason:
            'read, read, final answer — the relief is LM-free; '
            'output:\n${io.out}',
      );
      String textOf(Message message) => switch (message) {
        UserMessage(:final content) =>
          content is String
              ? content
              : (content as List<ContentBlock>)
                    .whereType<TextContent>()
                    .map((b) => b.text)
                    .join('\n'),
        AssistantMessage(:final content) || ToolResultMessage(:final content) =>
          content.whereType<TextContent>().map((b) => b.text).join('\n'),
        _ => '',
      };
      int estimate(Context context) => estimateRequestTokens(
        context.messages,
        systemPrompt: context.systemPrompt,
        tools: context.tools ?? const [],
      );
      // Precondition: request 2 still carried the first tool result.
      expect(
        stream.contexts[1].messages.map(textOf).join('\n'),
        contains('o' * 40),
      );
      final last = stream.contexts.last;
      final lastText = last.messages.map(textOf).join('\n');
      expect(
        last.messages.map(textOf),
        contains(prompt),
        reason: 'the newest user turn rides verbatim (gh-2411 invariant)',
      );
      expect(
        lastText,
        isNot(contains('o' * 40)),
        reason: 'the OLD tool result is gone — trimmed by the relief',
      );
      expect(
        estimate(last),
        lessThan(13000),
        reason: 'the post-pass estimate is under the window',
      );
      // The relief's own receipt: the pass that freed the window ran
      // exactly once.
      Iterable<String> receipts() => io.out
          .toString()
          .split('\n')
          .where(
            (line) => line.contains('continuing the turn on the compacted'),
          );
      expect(
        receipts(),
        hasLength(1),
        reason: 'the relief freed the window exactly once; output:\n${io.out}',
      );
      expect(
        io.out.toString().split('\n').where((line) => line.contains('freed')),
        isEmpty,
        reason: 'no LM pass ran (hide + valve only); output:\n${io.out}',
      );
      const warning =
          'context window 13000 is below the fixed request overhead';
      expect(
        warning.allMatches(io.out.toString()),
        hasLength(1),
        reason: 'ONE visible warning per session',
      );

      // A prompt whose request is UNDER the window (a fresh session in
      // the same regime): no pass runs — nothing is trimmed, nothing is
      // hidden; the skip is silent.
      final idle = FakeStreamFunction([textTurn('done again: nothing to do')]);
      final second = buildCli(
        idle,
        engine: CompactionEngine.classic,
        window: 13000,
        settings: const CompactionSettings(
          enabled: true,
          reserveTokens: 3250,
          keepRecentTokens: 100,
        ),
      );
      expect(await second.runHeadless(prompt), 0);
      expect(idle.calls, 1, reason: 'one request, the final answer');
      expect(
        receipts(),
        hasLength(1),
        reason: 'no re-run under the window; output:\n${io.out}',
      );
    },
  );

  test(
    'the [net] retry notice reaches headless output (issue #1121)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // Attempt 1 dies with a classified transient wording; attempt 2
      // recovers. The bench (fa -p) must SEE the retry.
      var calls = 0;
      final ctxSizes = <int>[];
      final base = FakeStreamFunction([textTurn('unused')]).call;
      // The retry ladder wraps the catalog fn in production; an injected
      // test fn composes it the same way — attempt 1 dies inside the
      // ladder with a transient wording, attempt 2 recovers.
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
          // gh-2411 follow-up: the REAL prompt's ~14.4k fixed overhead is
          // over this 12k window by itself — the loop guard stops such a
          // request now (a soft window stands down only UNDER it), which
          // would end the run before the retry ladder ever fires. The
          // seam keeps the scenario on the ladder: ~3.4k overhead.
          systemPrompt: tinyPrompt,
          runtimeTools: tinyTools(const ['read']),
          // gh-1380: structured sessions now carry the recall-hygiene
          // contract + the session_search schema; on this 12k window that
          // static overhead alone crosses the request-size compaction
          // threshold post-turn, and the structured summarizer adds 2
          // more stream calls. This scenario pins the retry ladder
          // (issue #1121) — compaction stays out of its call count.
          compactionSettings: const CompactionSettings(
            enabled: false,
            reserveTokens: 100,
            keepRecentTokens: 100,
          ),
        ),
        io: io,
        streamFunction: transientRetryStreamFunction((
          model,
          context, {
          cancelToken,
        }) {
          calls++;
          ctxSizes.add(context.messages.length);
          // ignore: avoid_print
          print('CALL $calls msgs=${context.messages.length}');
          if (calls >= 3) {
            // ignore: avoid_print
            print(
              'CALL$calls TRIGGER:\n${StackTrace.current.toString().split('\n').take(14).join('\n')}',
            );
          }
          if (calls == 1) {
            final stream = AssistantMessageEventStream();
            scheduleMicrotask(() {
              stream
                ..push(
                  ErrorEvent(
                    reason: StopReason.error,
                    error: testAssistant(
                      stopReason: StopReason.error,
                      errorMessage: 'SocketException: Connection reset by peer',
                    ),
                  ),
                )
                ..end();
            });
            return stream;
          }
          return base(model, context, cancelToken: cancelToken);
        }),
      );

      final exitCode = await cli.runHeadless('count the words');

      expect(exitCode, 0, reason: 'the retry recovered the run');
      expect(calls, 2);
      expect(
        io.out.toString(),
        contains('[net] connection lost'),
        reason: 'the transient ladder speaks on the headless surface too',
      );
      expect(
        io.out.toString(),
        contains('attempt 2/3'),
        reason: 'the notice announces the REPLAY (the first attempt died)',
      );
    },
  );
}
