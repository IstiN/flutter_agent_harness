/// The agent-facing `config` tool (issue #29 S3): op coverage over a
/// [MemoryExecutionEnv] and the `builtinTools` registration seam.
library;

import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/config/config_tool.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/tools/builtin_tools.dart';
import 'package:test/test.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/types.dart';

const _globalConfig = '/home/.fah/config.yaml';
const _projectConfig = '/work/.fah/config.yaml';

void main() {
  late MemoryExecutionEnv env;
  late AgentTool tool;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    tool = configTool(ConfigService(env: env, homeDir: '/home'));
  });

  Future<String> run(Map<String, dynamic> args) async {
    final result = await tool.execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }

  test('check prints notes and ok when both files are absent', () async {
    final text = await run({'op': 'check'});
    expect(text, contains('note: global config absent'));
    expect(text, contains('note: project config absent'));
    expect(text, endsWith('config check: ok\n'));
  });

  test('check reports a broken file as a named error', () async {
    await env.writeFile(_globalConfig, 'mcp: [not, a, map]');
    final text = await run({'op': 'check'});
    expect(text, contains('error: $_globalConfig'));
    expect(text, endsWith('config check: failed\n'));
  });

  test('path lists locations and marks absent files', () async {
    final text = await run({'op': 'path'});
    expect(text, contains('global config: /home/.fah/config.yaml'));
    expect(text, contains('project config: /work/.fah/config.yaml (absent)'));
  });

  test('get returns the effective value with scope and file', () async {
    await env.writeFile(_globalConfig, 'provider: zai\n');
    final text = await run({'op': 'get', 'key': 'provider'});
    expect(text, contains('provider = zai (global: $_globalConfig)'));
  });

  test('get reports not set without throwing', () async {
    expect(await run({'op': 'get', 'key': 'model'}), 'not set: model');
  });

  test('get rejects an unknown top-level key', () async {
    expect(
      await run({'op': 'get', 'key': 'notAKey'}),
      startsWith('error: unknown config key'),
    );
  });

  test('set writes through and answers file/scope/application', () async {
    final text = await run({
      'op': 'set',
      'key': 'memory.projectPath',
      'value': './memory',
    });
    expect(text, contains('memory.projectPath = ./memory (project:'));
    expect(text, contains('\n'), reason: 'the application note is a 2nd line');
    final read = await env.readTextFile(_projectConfig);
    expect(read.valueOrNull, contains('projectPath: ./memory'));
  });

  test('set refuses an invalid value and persists nothing', () async {
    await env.writeFile(_projectConfig, 'tools:\n  web_search: false\n');
    final text = await run({
      'op': 'set',
      'key': 'tools.web_search',
      'value': 'not-a-bool',
    });
    expect(text, startsWith('error: '));
    final read = await env.readTextFile(_projectConfig);
    expect(read.valueOrNull, contains('web_search: false'));
  });

  test(
    'set honors an explicit global scope for a project-capable key',
    () async {
      final text = await run({
        'op': 'set',
        'key': 'tools.web_search',
        'value': 'true',
        'scope': 'global',
      });
      expect(text, contains('(global: $_globalConfig)'));
    },
  );

  test('missing operands surface as error results, never exceptions', () async {
    expect(await run({'op': 'get'}), 'error: "key" is required for op "get"');
    expect(
      await run({'op': 'set', 'key': 'model'}),
      'error: "value" is required for op "set"',
    );
  });

  test('an unknown op is an error result (belt for the schema)', () async {
    expect(
      await run({'op': 'export'}),
      'error: unknown op: "export" (expected check|path|get|set)',
    );
  });

  test('builtinTools registers the tool when a service is provided', () {
    final tools = builtinTools(
      env,
      config: ConfigService(env: env, homeDir: '/home'),
    );
    expect(tools.where((t) => t.name == 'config'), hasLength(1));
    // The worst-case op mutates config: write tier.
    expect(tools.firstWhere((t) => t.name == 'config').tier.name, 'write');
  });

  test('builtinTools leaves the tool out without a service', () {
    expect(builtinTools(env).where((t) => t.name == 'config'), isEmpty);
  });
}
