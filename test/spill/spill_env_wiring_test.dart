// gh-1604 rework — the spill wiring's override observability.
//
// The `FAH_SPILL_THRESHOLD` env knob must announce what it does to a
// configured `spills:` section: retuning one prints the old → new
// threshold, disabling one says so, and the section's own tolerant-parse
// notes survive the composition (they are the diagnostics a bench run
// debugging its config needs).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  AgentCli cli({
    SpillsConfig? spills,
    Map<String, String> environment = const {},
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell()),
      sessionRoot: '/sessions',
      sessionName: 'spill-wiring',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      spills: spills,
    ),
    io: io,
    environment: environment,
    streamFunction: FakeStreamFunction([textTurn('ok')]),
  );

  test('env retuning an existing section announces old → new', () {
    cli(
      spills: const SpillsConfig(threshold: 8192),
      environment: {spillThresholdEnvVar: '2048'},
    ).attachSpillWiring();
    expect(
      io.out.toString(),
      contains(
        '[spills] threshold overridden via FAH_SPILL_THRESHOLD: '
        '8192 → 2048',
      ),
    );
  });

  test('env enabling with no section keeps the enabled notice', () {
    cli(environment: {spillThresholdEnvVar: '4096'}).attachSpillWiring();
    expect(
      io.out.toString(),
      contains('[spills] enabled via FAH_SPILL_THRESHOLD=4096'),
    );
  });

  test('env 0 disabling an active section announces the disable', () {
    cli(
      spills: const SpillsConfig(threshold: 8192),
      environment: {spillThresholdEnvVar: '0'},
    ).attachSpillWiring();
    expect(
      io.out.toString(),
      contains('[spills] disabled via FAH_SPILL_THRESHOLD=0'),
    );
  });

  test('no section + no env prints nothing (legacy silence)', () {
    cli().attachSpillWiring();
    expect(io.out.toString(), isNot(contains('[spills]')));
  });

  test('the section tolerant-parse notes still print under the env '
      'override', () {
    const section = SpillsConfig(
      threshold: 8192,
      notes: ['spills.tailChars: 10 below minimum 200, clamped'],
    );
    cli(
      spills: section,
      environment: {spillThresholdEnvVar: '2048'},
    ).attachSpillWiring();
    expect(
      io.out.toString(),
      contains('[spills] spills.tailChars: 10 below minimum 200, clamped'),
    );
    expect(
      io.out.toString(),
      contains('threshold overridden via FAH_SPILL_THRESHOLD'),
    );
  });
}
