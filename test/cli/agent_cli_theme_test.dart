// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Runtime `/theme` integration tests (issue #279 AC3/AC7): the real
/// command loop switches, persists `tui.theme`, boots from it, and
/// degrades under NO_COLOR.
library;

import 'dart:async';

import 'package:dart_tui/dart_tui.dart' show ColorProfile;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  AgentCli cliFor({
    bool useColor = false,
    Map<String, String> environment = const {},
    String? homeDir = '/home',
    String? tuiTheme,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        homeDir: homeDir,
        tuiTheme: tuiTheme,
      ),
      io: io,
      streamFunction: FakeStreamFunction(const []).call,
      useColor: useColor,
      environment: environment,
    );
  }

  /// Polls the (sync) output buffer until [condition] holds.
  Future<void> waitForOut(bool Function(String) condition) async {
    for (var i = 0; i < 200; i++) {
      if (condition(io.out.toString())) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for output; got:\n${io.out}');
  }

  Future<String> configFile(String path) async {
    final result = await env.readTextFile(path);
    return result.valueOrNull ?? '';
  }

  test('/theme bare lists the built-ins with the current marked', () async {
    final cli = cliFor();
    final run = cli.run();
    io.sendLine('/theme');
    await waitForOut((out) => out.contains('ohmypi-dark'));
    final out = io.out.toString();
    expect(out, contains('› default'));
    expect(out, contains('catppuccin'));
    expect(out, contains('ohmypi-light'));
    expect(out, contains('pi'));
    io.sendLine('/exit');
    await run;
  });

  test('/theme <name> switches, repaints and persists tui.theme', () async {
    final cli = cliFor(useColor: true);
    final run = cli.run();
    io.sendLine('/theme ohmypi-dark');
    await waitForOut((out) => out.contains('saved to'));
    final out = io.out.toString();
    expect(out, contains('theme: ohmypi-dark'));
    // The confirmation swatch is rendered in the NEW palette.
    expect(out, contains('\x1b[38;2;254;188;56m'));
    expect(FaThemeController.instance.currentName, 'ohmypi-dark');
    // Subsequent emitters use the new palette (next frame is repainted).
    expect(tuiAccent('x'), contains('38;2;254;188;56'));

    expect(
      await configFile('/home/.fah/config.yaml'),
      contains('theme: ohmypi-dark'),
      reason: 'a theme is a user preference - global scope',
    );
    io.sendLine('/exit');
    await run;
  });

  test('/theme reset returns to the default and persists it', () async {
    final cli = cliFor();
    final run = cli.run();
    io.sendLine('/theme pi');
    await waitForOut((out) => out.contains('theme: pi'));
    io.sendLine('/theme reset');
    await waitForOut((out) => out.contains('theme: default'));
    expect(FaThemeController.instance.currentName, 'default');
    io.sendLine('/exit');
    await run;
  });

  test('/theme with an unknown name is a named error, nothing persisted',
      () async {
    final cli = cliFor();
    final run = cli.run();
    io.sendLine('/theme solarized');
    await waitForOut((out) => out.contains('unknown theme: solarized'));
    expect(io.out.toString(), contains('ohmypi-dark'));
    io.sendLine('/exit');
    await run;
    // No config file was written by the failed switch.
    expect(await configFile('/work/.fah/config.yaml'), isEmpty);
    expect(FaThemeController.instance.currentName, 'default');
  });

  test('boot applies the persisted tui.theme', () {
    cliFor(tuiTheme: 'pi');
    expect(FaThemeController.instance.currentName, 'pi');
  });

  test('boot with an unknown tui.theme warns and keeps the default', () {
    cliFor(tuiTheme: 'solarized');
    expect(io.out.toString(), contains('unknown theme "solarized"'));
    expect(FaThemeController.instance.currentName, 'default');
  });

  test('colored sessions get the truecolor profile', () {
    cliFor(useColor: true);
    expect(FaThemeController.instance.profile, ColorProfile.trueColor);
    expect(tuiAccent('x'), '\x1b[1m\x1b[38;2;94;234;212mx\x1b[0m');
  });

  test('NO_COLOR degrades the whole session to plain text', () {
    cliFor(useColor: true, environment: {'NO_COLOR': '1'});
    expect(FaThemeController.instance.profile, isNull);
    expect(tuiAccent('x'), 'x');
    expect(tuiDim('x'), 'x');
  });
}
