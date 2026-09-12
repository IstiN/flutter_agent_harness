// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AC12 (issue #29): cross-surface consistency. For the same key, the CLI
/// (`fa config get/set` — the real [runConfigServiceCommand] the binary
/// routes to), the agent `config` tool, and the app's settings stores
/// resolve IDENTICAL effective values and the same scope attribution:
///
/// - CLI and tool ride the same pure [ConfigService], so the test pins the
///   SURFACES (rendered text, exit codes, scope attribution) against drift;
/// - the app stores (ApprovalModeStore / ToolsAvailabilityStore /
///   SkillsAccessStore / loadAppMemoryConfig) use their own persistence but
///   the same shared domain types — the test pins that the same setting
///   resolves to the same typed value on every surface, and that the app's
///   project-over-home precedence matches the config service's.
library;

import 'dart:async';
import 'dart:io';

import 'package:fa/services/approval_mode_store.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/services/tools_availability_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa/services/memory_config_loader.dart';
import 'package:yaml/yaml.dart';

/// Captures the CLI surface's output (the binary routes stdout here).
final class _CaptureIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final out = StringBuffer();

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.writeln(text);

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => const Stream.empty();

  @override
  Stream<KeyEvent> get keys => const Stream.empty();

  @override
  bool get supportsRawMode => false;

  @override
  bool get isInteractive => false;
}

void main() {
  late Directory home;
  late Directory project;
  late LocalExecutionEnv env;
  late ConfigService service;
  late AgentTool tool;

  Future<(int, String)> cli(
    String verb, [
    String? key,
    String? value,
    ConfigScope? scope,
  ]) async {
    final io = _CaptureIO();
    final code = await runConfigServiceCommand(
      ConfigCliCommand(verb: verb, key: key, value: value, scope: scope),
      io: io,
      env: env,
      homeDir: home.path,
    );
    return (code, io.out.toString());
  }

  Future<String> toolGet(String key) async {
    final result = await tool.execute({'op': 'get', 'key': key}, null, null);
    return result.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join();
  }

  setUpAll(() {
    home = Directory.systemTemp.createTempSync('ac12_home');
    project = Directory.systemTemp.createTempSync('ac12_project');
    Directory('${home.path}/.fah').createSync();
    Directory('${project.path}/.fah').createSync();
    env = LocalExecutionEnv(cwd: project.path);
    service = ConfigService(env: env, homeDir: home.path);
    tool = configTool(service);
  });

  tearDownAll(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  test(
    'memory.projectPath: identical value, project scope wins everywhere',
    () async {
      // The agent surface writes; every surface then reads the same value.
      final setOut = await tool.execute(
        {'op': 'set', 'key': 'memory.projectPath', 'value': './memory'},
        null,
        null,
      );
      final setText = setOut.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      expect(setText, contains('(project:')); // scope attribution

      final (cliCode, cliOut) = await cli('get', 'memory.projectPath');
      expect(cliCode, 0);
      expect(cliOut.trim(), './memory');
      expect(await toolGet('memory.projectPath'), contains('./memory'));
      expect((await service.get('memory.projectPath')).scope, 'project');

      // The app's resolver: same effective value, same project-first order.
      expect(loadAppMemoryConfig(project.path)?.projectPath, './memory');

      // A global-scope value loses to the project one on every surface.
      await cli(
        'set',
        'memory.projectPath',
        './home-memory',
        ConfigScope.global,
      );
      expect((await cli('get', 'memory.projectPath')).$2.trim(), './memory');
      expect(loadAppMemoryConfig(project.path)?.projectPath, './memory');
      File('${project.path}/.fah/config.yaml').deleteSync();
      // ...and resolves from home when no project file declares it. The
      // app's home branch is `loadCliConfig(home).memory` verbatim
      // (memory_config_loader_io.dart); the process env pins HOME outside
      // the test, so pin the branch's core call against the same home.
      expect(loadProjectMemoryConfig(project.path), isNull);
      expect(loadCliConfig(home.path).memory?.projectPath, './home-memory');
    },
  );

  test(
    'approvalMode: CLI label, tool and app store agree on the typed value',
    () async {
      final (_, setOut) = await cli('set', 'approvalMode', 'unattended');
      expect(setOut, contains('(global:')); // scope attribution

      final (cliCode, cliOut) = await cli('get', 'approvalMode');
      expect(cliCode, 0);
      expect(cliOut.trim(), 'unattended');
      expect(await toolGet('approvalMode'), contains('unattended'));

      // The app store resolves the same typed setting.
      final store = ApprovalModeStore(env);
      await store.save(ApprovalMode.unattended);
      final appMode = await store.load();
      expect(appMode, ApprovalMode.unattended);
      // The CLI's label resolves to exactly the app's enum value.
      expect(approvalModeFromLabel(cliOut.trim()), appMode);
    },
  );

  test(
    'tools.web_search: config file and app store resolve one ToolsConfig',
    () async {
      await cli('set', 'tools.web_search', 'false');
      expect((await cli('get', 'tools.web_search')).$2.trim(), 'false');
      expect(await toolGet('tools.web_search'), contains('false'));

      // The app store's JSON envelope and the CLI's yaml both decode to the
      // same ToolsConfig — the formats are interchangeable by contract.
      final store = ToolsAvailabilityStore(env);
      await store.save(const ToolsConfig(tools: {'web_search': false}));
      final appConfig = await store.load();
      expect(appConfig!.tools, {'web_search': false});

      final doc =
          loadYaml(File('${project.path}/.fah/config.yaml').readAsStringSync())
              as YamlMap;
      final fromConfigFile = ToolsConfig.fromYaml(doc['tools']);
      expect(fromConfigFile.tools, appConfig.tools);
    },
  );

  test(
    'skills.access: CLI value and app store resolve the same SkillsAccess',
    () async {
      await cli('set', 'skills.access', 'denied');
      expect((await cli('get', 'skills.access')).$2.trim(), 'denied');

      final store = SkillsAccessStore(env);
      await store.save(SkillsAccess.denied);
      final appAccess = await store.load();
      expect(appAccess, SkillsAccess.denied);
      expect(appAccess!.name, (await cli('get', 'skills.access')).$2.trim());
    },
  );

  test('a global-only scalar surfaces identically on CLI and tool', () async {
    await cli('set', 'model', 'openai/gpt-4o-mini');
    final (code, out) = await cli('get', 'model');
    expect(code, 0);
    expect(out.trim(), 'openai/gpt-4o-mini');
    final toolOut = await toolGet('model');
    expect(toolOut, contains('openai/gpt-4o-mini'));
    expect(toolOut, contains('(global:')); // scope attribution
    expect((await service.get('model')).scope, 'global');
  });

  test(
    'all surfaces validate the same files: check is one rendering',
    () async {
      final (code, out) = await cli('check');
      expect(code, 0);
      final report = await service.check();
      expect(out, renderConfigCheckReport(report));
      final toolOut = await tool.execute(const {'op': 'check'}, null, null);
      expect(
        toolOut.content.whereType<TextContent>().map((b) => b.text).join(),
        renderConfigCheckReport(report),
      );
    },
  );
}
