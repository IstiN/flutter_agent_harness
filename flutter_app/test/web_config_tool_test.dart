// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AC11 (issue #29): the `config` tool works over the browser-storage and
/// container ExecutionEnvs, platform-inapplicable keys answer "not
/// applicable on this host" instead of being written, and web config
/// survives a page reload (persistence through the snapshot store).
library;

import 'package:fa/sandbox/fs_persistence.dart';
import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/persistent_web_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the web wiring in `env_factory_stub.dart`: a MemoryShell-backed
/// MemoryExecutionEnv wrapped for persistence — the browser-storage env.
Future<PersistentWebExecutionEnv> _restoreWebEnv(FsSnapshotStore store) async {
  final shell = MemoryShell();
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  return PersistentWebExecutionEnv.restore(
    env,
    store,
    persistDelay: const Duration(milliseconds: 20),
  );
}

void main() {
  test('web config survives a page reload (persistence test)', () async {
    final store = InMemoryFsSnapshotStore();
    final before = await _restoreWebEnv(store);
    final beforeService = ConfigService(
      env: before,
      homeDir: null, // web: no home directory
      supportsProcesses: false, // web: no host process spawning
    );

    await beforeService.set('memory.projectPath', './memory');
    await beforeService.set('tools.web_search', 'false');
    final checkBefore = await beforeService.check();
    expect(checkBefore.ok, isTrue, reason: checkBefore.errors.join('; '));

    await before.flush(); // the debounced snapshot lands in the store
    before.dispose();

    // A fresh env restored from the SAME storage — the "reload".
    final after = await _restoreWebEnv(store);
    final afterService = ConfigService(
      env: after,
      homeDir: null,
      supportsProcesses: false,
    );

    final memory = await afterService.get('memory.projectPath');
    expect(memory.found, isTrue);
    expect(memory.display, './memory');
    expect(memory.scope, 'project');
    final tools = await afterService.get('tools.web_search');
    expect(tools.found, isTrue);
    expect(tools.display, 'false');
    final checkAfter = await afterService.check();
    expect(checkAfter.ok, isTrue, reason: checkAfter.errors.join('; '));
    after.dispose();
  });

  test('the config tool drives the web env — no shell anywhere', () async {
    final store = InMemoryFsSnapshotStore();
    final env = await _restoreWebEnv(store);
    final service = ConfigService(
      env: env,
      homeDir: null,
      supportsProcesses: false,
    );
    final tool = configTool(service);
    Future<String> call(Map<String, dynamic> args) async {
      final result = await tool.execute(args, null, null);
      return result.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
    }

    final setOut = await call({
      'op': 'set',
      'key': 'memory.projectPath',
      'value': './notes',
    });
    expect(setOut, contains('memory.projectPath = ./notes'));
    expect(setOut, contains('(project:'));
    final getOut = await call({'op': 'get', 'key': 'memory.projectPath'});
    expect(getOut, contains('./notes'));
    final checkOut = await call({'op': 'check'});
    expect(checkOut, contains('config check: ok'));
    await env.flush();
    env.dispose();
  });

  test('stdio-only keys answer not applicable on the web env', () async {
    final store = InMemoryFsSnapshotStore();
    final env = await _restoreWebEnv(store);
    final service = ConfigService(
      env: env,
      homeDir: null,
      supportsProcesses: false,
    );
    final tool = configTool(service);
    final setResult = await tool.execute(
      {'op': 'set', 'key': 'mcp.servers.fs.command', 'value': 'npx'},
      null,
      null,
    );
    final setOut = setResult.content
        .whereType<TextContent>()
        .map((block) => block.text)
        .join();
    expect(setOut, contains('not applicable on this host'));

    // The remote (`url`) flavor is not process-bound, but a home-less host
    // still has nowhere to persist a global-scope key: the honest refusal
    // (the remote/stdio distinction is pinned in the core service tests).
    await expectLater(
      service.set('mcp.servers.web', '{"url": "https://mcp.example"}'),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('global scope unavailable on this host'),
        ),
      ),
    );
    // Same honesty for any other global-only key.
    await expectLater(
      service.set('provider', 'openai-completions'),
      throwsA(isA<ConfigException>()),
    );
    await env.flush();
    env.dispose();
  });

  test('the container env (memory FS) round-trips config', () async {
    // The mobile container shape: an in-memory FS with a cwd, no home.
    final env = MemoryExecutionEnv(cwd: '/sandbox');
    final service = ConfigService(
      env: env,
      homeDir: null,
      supportsProcesses: false,
    );
    await service.set('memory.projectPath', './memory');
    await service.set('cube.enabled', 'false');
    expect((await service.get('memory.projectPath')).display, './memory');
    expect((await service.get('cube.enabled')).display, 'false');
    final report = await service.check();
    expect(report.ok, isTrue, reason: report.errors.join('; '));
  });
}
