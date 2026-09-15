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

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    // The overflow payload: a real tool result the `read` tool returns in
    // full (short lines stay under its line cap; ~46k chars ≈ 11.5k
    // estimated tokens) — not a split assistant turn, so the classic
    // prefix compaction hides it cleanly.
    env.writeFile('big.txt', List.filled(1000, 'x' * 45).join('\n'));
  });

  tearDown(() => io.close());

  // 12k window: the harness's system-prompt + tool-schema overhead (~8.5k
  // estimated tokens) still fits request 1, while the 100k-char (~25k
  // token) reply overflows request 2 — the guard fires MID-TURN, not
  // before the first request.
  AgentCli buildCli(
    FakeStreamFunction stream, {
    CompactionEngine? engine,
    CompactionSettings? settings,
  }) => AgentCli(
    config: AgentCliConfig(
      model: const Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 12000,
        maxTokens: 4096,
      ),
      apiKey: '[REDACTED:Sensitive Value]',
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
      // ~11.5k tokens → the loop's guard refuses request 2. On main since
      // #417 the loop retries with its own intra-loop compaction first
      // (call 2, frees nothing here), then lands the error stop; the
      // settle path's compaction (call 3) hides the tool result and frees
      // the window → the continuation turn (call 4) finishes the task.
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

      // Guard stop → intra-loop compaction attempt (call 2, frees
      // nothing) → settle-path compaction (call 3, frees the window) →
      // continuation turn (call 4): the task DROVE TO COMPLETION.
      expect(exitCode, 0, reason: 'the continued turn finished normally');
      expect(
        stream.calls,
        4,
        reason:
            'guard refused request 2; two compaction attempts + '
            'continuation follow',
      );
      // The continuation is the notice prompt, not a bare retry of the
      // original user text.
      final lastPrompt = stream.contexts[3].messages
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
        contains('could not free the context window'),
        reason: 'the settle path ran: the note follows the compact attempt',
      );
    },
  );
}
