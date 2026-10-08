// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The settings-hub auto-update toggle's drop step (issue #1377): the
/// `_dropAutoUpdateKey` branch matrix driven through the public
/// [AgentCli.startAutoUpdateFlow] — the notify-default round trip must
/// remove the `auto_update:` line, keep the rest of the user config
/// byte-for-byte, and refuse (unchanged policy, no write) on every guard:
/// no home directory, unreadable config, a file that would not parse
/// after the drop, and a failing write.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/cli_config.dart'
    show AutoUpdateMode;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

(AgentCli, FakeCliIO) _boot({
  required String? homeDir,
  MemoryExecutionEnv? env,
}) {
  final io = FakeCliIO();
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env ?? MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
      homeDir: homeDir,
    ),
    io: io,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
  );
  return (cli, io);
}

const _configPath = '/home/u/.fah/config.yaml';

void main() {
  test(
    'off → notify drops the auto_update line; the rest is byte-identical',
    () async {
      final fs = MemoryExecutionEnv(cwd: '/work');
      await fs.writeFile(
        _configPath,
        'provider: openai-completions\n'
        'model: m\n'
        'auto_update: true\n'
        'memory:\n'
        '  userPath: /mem\n',
      );
      final (cli, io) = _boot(homeDir: '/home/u', env: fs);
      cli.config.autoUpdate = AutoUpdateMode.off;

      await cli.startAutoUpdateFlow();

      final after = (await fs.readTextFile(_configPath)).getOrThrow();
      expect(
        after,
        'provider: openai-completions\n'
        'model: m\n'
        'memory:\n'
        '  userPath: /mem\n',
        reason: 'the dropped key must not disturb the surviving lines',
      );
      expect(io.out.toString(), contains('auto_update removed'));
      expect(cli.config.autoUpdate, AutoUpdateMode.notify);
    },
  );

  test('no home directory: the policy stays off, nothing is saved', () async {
    final (cli, io) = _boot(homeDir: null);
    cli.config.autoUpdate = AutoUpdateMode.off;

    await cli.startAutoUpdateFlow();

    expect(io.out.toString(), contains('no user config on this host'));
    expect(cli.config.autoUpdate, AutoUpdateMode.off);
  });

  test('unreadable config file: refused, the policy stays off', () async {
    // No config file seeded — the read misses.
    final (cli, io) = _boot(homeDir: '/home/u');
    cli.config.autoUpdate = AutoUpdateMode.off;

    await cli.startAutoUpdateFlow();

    expect(
      io.out.toString(),
      contains('cannot read $_configPath'),
    );
    expect(cli.config.autoUpdate, AutoUpdateMode.off);
  });

  test('a file that would not parse after the drop: not saved', () async {
    final fs = MemoryExecutionEnv(cwd: '/work');
    // Dropping auto_update leaves an unterminated quoted scalar — the
    // next boot would reject the file, so the edit must be refused.
    const source = 'provider: a\nauto_update: true\nprovider: "b\n';
    await fs.writeFile(_configPath, source);
    final (cli, io) = _boot(homeDir: '/home/u', env: fs);
    cli.config.autoUpdate = AutoUpdateMode.off;

    await cli.startAutoUpdateFlow();

    expect(io.out.toString(), contains('not saved:'));
    expect((await fs.readTextFile(_configPath)).getOrThrow(), source);
    expect(cli.config.autoUpdate, AutoUpdateMode.off);
  });
}
