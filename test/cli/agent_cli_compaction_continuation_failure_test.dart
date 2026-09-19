// Issue #673 AC4 — the over-window continuation's named-error guard.
//
// The AC4 wrapper around the auto-continuation must turn ANY failure of
// the continuation machinery into `error: compaction continuation
// failed: ...` and leave the session alive. Forcing that failure
// deterministically (mock LLM only): the continuation turn returns a
// CodeMie auth-expired provider error, and a bombing CliIO makes the
// error-handling writes themselves throw — the inner failure escapes
// _runPrompt's own error handler (its error-line write is the second
// shot) and lands in the AC4 catch, which prints the named error and
// returns the CLI to an idle, resumable prompt.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [FakeCliIO] whose first [shots] writeln calls carrying [marker]
/// throw — a dying terminal while the turn is being handled.
class _BombingIO extends FakeCliIO {
  _BombingIO(this.marker, this.shots);

  final String marker;
  int shots;

  @override
  void writeln(String text) {
    if (shots > 0 && text.contains(marker)) {
      shots--;
      throw StateError('bomb: io exploded writing $marker');
    }
    super.writeln(text);
  }
}

void main() {
  test('a failing over-window continuation surfaces the named error and '
      'keeps the session resumable (AC4)', () async {
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
    // Suppress session-start memory maintenance so the scripted turns
    // feed only the turn under test (same pattern as agent_cli_test).
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');

    final io = _BombingIO('BOOM', 2);
    final fake = FakeStreamFunction([
      // The guard's over-window shape (same as the 'over-window guard
      // auto-compacts and continues the turn' test): three tool calls
      // whose outputs (~8200 tokens each) balloon the next request past
      // the window, all droppable so the summarizer frees it.
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
      // Consumed by the mid-run relief's no-op compaction attempt.
      textTurn('S'),
      // Consumed as the post-run compaction summary.
      textTurn('S'),
      // The continuation turn itself fails: a provider error carrying
      // the CodeMie auth-expired marker. Its handler writes to the io —
      // the bomb's first shot turns that write into a throw, which
      // escapes _runPrompt's own error handler (its error-line write is
      // the second shot) and lands in the AC4 catch.
      [
        ErrorEvent(
          reason: StopReason.error,
          error: testAssistant(
            stopReason: StopReason.error,
            errorMessage: 'BOOM provider redirected [[auth-expired:codemie]]',
          ),
        ),
      ],
      // Only reachable when the AC4 catch swallowed the failure and the
      // CLI stayed alive for the next prompt.
      textTurn('resumed fine'),
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
      () => fake.calls >= 4 && !cli.isBusy,
      reason: 'the failed continuation settles back to idle',
    );

    final output = io.out.toString();
    // The AC4 catch printed the NAMED error — never a bare crash line.
    expect(output, contains('error: compaction continuation failed:'));
    // The SSO flow never started: the bomb fired on its first write.
    expect(output, isNot(contains('CodeMie session expired')));

    // The session is resumable: the next prompt runs to its answer.
    io.sendLine('again');
    await waitForIt(
      () => fake.calls >= 5 && !cli.isBusy,
      reason: 'the next prompt runs after the failed continuation',
    );
    expect(io.out.toString(), contains('resumed fine'));

    io.sendLine('/exit');
    await run;
    await io.close();
  });
}
