// gh-1604 rework — the spill wiring's override observability.
//
// The `FAH_SPILL_THRESHOLD` env knob must announce what it does to a
// configured `spills:` section: retuning one prints the old → new
// threshold, disabling one says so, and the section's own tolerant-parse
// notes survive the composition (they are the diagnostics a bench run
// debugging its config needs).
import 'dart:io';

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
      apiKey: '[REDACTED:Sensitive-Value]',
      env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell()),
      sessionRoot: '/sessions',
      sessionName: 'spill-wiring',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      spills: spills,
    ),
    io: io,
    environment: environment,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
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

  test('a PROJECT spills section wins over the (absent) user section — '
      'the app-host parity (gh-2411 rework review)', () async {
    // The CLI boot resolves loadProjectSpillsConfig(cwd) ?? config.spills,
    // exactly like bin/fah_runapp.dart. The loader reads the REAL
    // filesystem (dart:io), so the project file lives in a real temp dir;
    // the env-retune probe makes the applied threshold observable: with
    // the project file picked up, the retune announces 1024 → 512 (not
    // the 'enabled via' legacy silence).
    final dir = await Directory.systemTemp.createTemp('fah-spill-proj');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/.fah').create();
    await File(
      '${dir.path}/.fah/config.yaml',
    ).writeAsString('spills:\n  threshold: 1024\n');
    AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: MemoryExecutionEnv(cwd: dir.path, shell: FakeShell()),
        sessionRoot: '/sessions',
        sessionName: 'spill-wiring-project',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
      ),
      io: io,
      environment: {spillThresholdEnvVar: '512'},
    ).attachSpillWiring();
    expect(
      io.out.toString(),
      contains(
        '[spills] threshold overridden via FAH_SPILL_THRESHOLD: '
        '1024 → 512',
      ),
    );
  });
}
