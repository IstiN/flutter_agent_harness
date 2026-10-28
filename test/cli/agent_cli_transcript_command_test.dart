import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tool_row_content.dart'
    show transcriptExpandDetails;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The `/transcript expand all|none` command (gh-1933): the state report
/// and usage answer anywhere, and — review thread PRRT_kwDOTXdlLc6w5WG8 —
/// the mutating arms say so on a non-TUI face instead of confirming a
/// no-op: outside the TUI chrome face the expansion state renders nothing
/// observable, so the render flag must stay untouched there too.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    '/transcript expand toggles the collapsed-detail state (gh-1933)',
    () async {
      // Session-start memory maintenance is due on a fresh env (no stamp);
      // its consolidate() would consume a scripted turn on a slow runner.
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      addTearDown(() => transcriptExpandDetails = false);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      io.sendLine('/transcript');
      io.sendLine('/transcript expand all');
      io.sendLine('/transcript expand bogus');
      io.sendLine('/transcript expand none');
      io.sendLine('/exit');
      await run;
      final out = io.out.toString();
      expect(
        out,
        contains('transcript rows are collapsed'),
        reason: 'bare /transcript reports the state',
      );
      // Review thread PRRT_kwDOTXdlLc6w5WG8: outside the TUI chrome face the
      // expansion state renders nothing observable (line mode streams
      // thinking per-delta or never; the line replay renders thinking NEVER)
      // — the mutating arms say so instead of confirming a no-op.
      expect(
        out,
        contains('transcript expand only affects the TUI chrome transcript'),
        reason: 'this harness is the line-mode (non-TUI) face',
      );
      expect(out, contains('usage: /transcript expand all|none'));
      expect(
        transcriptExpandDetails,
        isFalse,
        reason: 'a non-TUI face leaves the render state alone',
      );
      expect(cli.isBusy, isFalse);
    },
  );
}
