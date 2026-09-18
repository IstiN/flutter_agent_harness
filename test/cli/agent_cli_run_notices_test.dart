import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The run-notice wiring (`[net]` retry / `[images]` drop lines) lives in
/// the `agent_cli_io.dart` size-gate split, out of reach of the full
/// `AgentCli.run` — [AgentCli.wireRunNoticesForTesting] reaches in instead.
/// Issue #312: the CI coverage ratchet counts those moved lines; these
/// tests keep them covered.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
    transientRetryNotice = null;
    imageDropNotice = null;
  });

  test('the transient retry notice prints a dim transcript line', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();

    transientRetryNotice?.call(
      1,
      3,
      const Duration(seconds: 5),
      'Connection reset by peer',
    );

    expect(
      io.out.toString(),
      contains('[net] connection lost (Connection reset by peer)'),
    );
    expect(io.out.toString(), contains('retrying in 5s (attempt 2/3)'));
  });

  test('the image drop notice prints a dim transcript line', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();

    imageDropNotice?.call(2, 'a1b2c3');

    expect(
      io.out.toString(),
      contains('[images] dropping [Image 2] (key a1b2c3…)'),
    );
    expect(io.out.toString(), contains('per-request cap reached'));
  });

  test('the text-only image drop notice prints a visible line (issue #638)', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();

    textOnlyImageDropNotice?.call(2);

    expect(io.out.toString(), contains('[images] 2 image(s) dropped'));
    expect(
      io.out.toString(),
      contains('model declared text-only'),
    );
  });
}
