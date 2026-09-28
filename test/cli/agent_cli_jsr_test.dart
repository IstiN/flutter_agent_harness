import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/jsr_cli.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// REPL-wiring tests for the `/jsr` alias (gh-1033): the slash command
/// routes onto the SAME delegate as the headless `fa jsr` subcommand —
/// fake jsr package + scripted shell, no real flutter.

/// A scripted [Shell] recording the command the delegate built.
final class ScriptedShell implements Shell {
  final commands = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    options?.onStdout?.call('widget test: ok\n');
    return Ok(
      const ShellExecResult(
        stdout: 'widget test: ok\n',
        stderr: '',
        exitCode: 0,
      ),
    );
  }
}

void main() {
  const projectDir = '/work';
  const jsrRoot = '/pub/js_widget_runtime-0.4.126';
  const flutterBin = '/flutter/bin';

  test(
    '/jsr widget:test runs the jsr delegate through the session env',
    () async {
      final shell = ScriptedShell();
      final env = MemoryExecutionEnv(cwd: projectDir, shell: shell);
      await env.writeFile(
        '$projectDir/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'js_widget_runtime',
              'rootUri': 'file://$jsrRoot',
              'languageVersion': '3.12',
            },
          ],
        }),
      );
      await env.writeFile('$jsrRoot/bin/jsr_widget.dart', 'void main() {}');
      await env.writeFile('$flutterBin/flutter', '#!/bin/sh\n');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          homeDir: '/home',
          envVarValue: (name) => name == 'PATH' ? flutterBin : null,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final run = cli.run();
      await waitForIt(() => io.out.toString().contains('fa>'));

      io.sendLine('/jsr widget:test calc --event btn_7 --json');
      await waitForIt(() => shell.commands.isNotEmpty);
      expect(
        shell.commands.single,
        'dart "$jsrRoot/bin/jsr_widget.dart" widget:test calc '
        '--event btn_7 --json',
      );
      await waitForIt(() => io.out.toString().contains('widget test: ok'));
      io.sendLine('/exit');
      await run;
      // No failed-run noise.
      expect(io.out.toString(), isNot(contains('/jsr: exited with code')));
      await io.close();
    },
  );

  test('/jsr with an unknown verb prints usage, no exec', () async {
    final shell = ScriptedShell();
    final env = MemoryExecutionEnv(cwd: projectDir, shell: shell);
    final io = FakeCliIO();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        homeDir: '/home',
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa>'));

    io.sendLine('/jsr frobnicate');
    await waitForIt(() => io.out.toString().contains('usage: /jsr'));
    expect(shell.commands, isEmpty);
    io.sendLine('/exit');
    await run;
    await io.close();
  });
}
