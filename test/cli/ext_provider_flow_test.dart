/// AC5 + E10 acceptance tests: JS-registered provider flows render in the
/// CLI provider surface, run their wizard through the shared line-prompt
/// helpers, and persist through the host bridges (secure store + custom
/// provider registry) — the extension never touches files itself. Driven
/// entirely through FakeJsrRuntime and line-mode FakeCliIO.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

var _handles = 0;

/// A commit payload with [flows] (and one marker tool so tests can await
/// the load via the observable tool registry).
Map<String, Object?> _commit(List<Map<String, Object?>> flows) => {
  'tools': [
    {'name': 'acme_tool', 'description': 'load marker', 'handle': _handles++},
  ],
  'flows': [
    for (final flow in flows) {...flow, 'handle': _handles++},
  ],
};

Map<String, Object?> _setupFlow() => {
  'id': 'setup',
  'title': 'Acme Setup',
  'description': 'connect an Acme account',
  'fields': [
    {'name': 'host', 'label': 'Acme host'},
    {'name': 'token', 'label': 'Acme token', 'secret': true},
  ],
};

Future<void> _install(MemoryExecutionEnv env, String name) async {
  final store = ExtensionStore(env: env, projectDir: '/work', userDir: '/home');
  await store.write(
    name,
    files: {
      'manifest.json': jsonEncode({
        'name': name,
        'kind': 'cli-extension',
        'version': '1.0.0',
        'capabilities': {'tools': true, 'menus': true},
      }),
      'main.js': '// test extension',
    },
    trust: TrustRecord(
      source: ExtTrustSource.local,
      sourceRef: '/work/.fah/js-ext/$name',
      contentSha256: 'deadbeef',
      capabilities: const {'tools': true, 'menus': true},
      grantedAt: DateTime.utc(2026, 1, 1),
    ),
  );
}

Future<void> _installToolOnly(MemoryExecutionEnv env, String name) async {
  final store = ExtensionStore(env: env, projectDir: '/work', userDir: '/home');
  await store.write(
    name,
    files: {
      'manifest.json': jsonEncode({
        'name': name,
        'kind': 'cli-extension',
        'version': '1.0.0',
        'capabilities': {'tools': true},
      }),
      'main.js': '// test extension',
    },
    trust: TrustRecord(
      source: ExtTrustSource.local,
      sourceRef: '/work/.fah/js-ext/$name',
      contentSha256: 'deadbeef',
      capabilities: const {'tools': true},
      grantedAt: DateTime.utc(2026, 1, 1),
    ),
  );
}

class _Harness {
  final AgentCli cli;
  final FakeCliIO io;
  final FakeSecureKeyStore store;
  final CustomProviderRegistry registry;
  final List<Map<String, String>> received = [];
  final List<(String, String)> providerChanges = [];
  final List<(String, String)> secretsStored = [];
  Object? submitResult;
  Object? submitError;

  _Harness._(this.cli, this.io, this.store, this.registry);

  static Future<_Harness> boot(
    MemoryExecutionEnv env,
    FakeCliIO io, {
    required Map<String, Object?> Function() commit,
  }) async {
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final registry = CustomProviderRegistry([]);
    // The runtime closure reads [harness] lazily — flows only invoke after
    // boot finished the assignment.
    late final _Harness harness;
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        homeDir: '/home',
        extRuntimeFactory: (ext) => FakeJsrRuntime('fake')
          ..onGlobal('__extCommit', (args) async => commit())
          ..onGlobal('__extInvoke', (args) async {
            harness.received.add(Map<String, String>.from(args[1] as Map));
            if (harness.submitError != null) throw harness.submitError!;
            return harness.submitResult;
          }),
        secureKeys: cache,
        customProviders: registry,
        envVarValue: (_) => null,
        onProviderChanged: (kind, key) async =>
            harness.providerChanges.add((kind, key)),
        onSecretStored: (name, value) =>
            harness.secretsStored.add((name, value)),
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    harness = _Harness._(cli, io, store, registry);
    final run = cli.run();
    await waitForIt(
      () =>
          harness.cli.agent.state.tools.any((tool) => tool.name == 'acme_tool'),
    );
    harness.run = run;
    return harness;
  }

  late Future<void> run;

  Future<void> exit() async {
    io.sendLine('/exit');
    await run;
    io.close();
  }
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    _handles = 0;
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  test('menu lists extension flows under their namespaced keys', () async {
    await _install(env, 'acme');
    final h = await _Harness.boot(
      env,
      io,
      commit: () => _commit([_setupFlow()]),
    );

    io.sendLine('/provider');
    await waitForIt(() => io.out.toString().contains('extension providers:'));

    final out = io.out.toString();
    expect(out, contains('Acme Setup (ext:acme)'));
    expect(out, contains('connect an Acme account'));
    // E10: the menu key is the full namespaced map key, never a bare id.
    expect(out, contains('/provider ext:acme:setup'));
    await h.exit();
  });

  test(
    'wizard round-trips values to JS and persists key + registry entry',
    () async {
      await _install(env, 'acme');
      final h =
          await _Harness.boot(env, io, commit: () => _commit([_setupFlow()]))
            ..submitResult = {
              'providerName': 'acme-main',
              'baseUrl': 'https://api.acme.dev/v1',
              'apiKey': 'sk-acme-9',
              'modelName': 'acme-large',
            };

      io.sendLine('/provider ext:acme:setup');
      await waitForIt(
        () => io.out.toString().contains('Acme Setup (ext:acme)'),
      );
      await waitForIt(() => io.out.toString().contains('Acme host: '));
      io.sendLine('api.acme.dev');
      await waitForIt(() => io.out.toString().contains('Acme token: '));
      io.sendLine('sk-acme-1');
      await waitForIt(
        () => io.out.toString().contains('ext provider acme-main saved'),
      );

      // The JS onSubmit received exactly the collected field values.
      expect(h.received, [
        {'host': 'api.acme.dev', 'token': 'sk-acme-1'},
      ]);
      // The apiKey landed in the secure store under the host-scoped name.
      expect(h.store.map['FA_KEY_API_ACME_DEV'], 'sk-acme-9');
      expect(h.secretsStored, contains(('FA_KEY_API_ACME_DEV', 'sk-acme-9')));
      // The registry entry went through the custom wizard's append seam.
      final entry = h.registry.find('acme-main');
      expect(entry, isNotNull);
      expect(entry!.baseUrl, 'https://api.acme.dev/v1');
      expect(entry.modelId, 'acme-large');
      expect(entry.keyName, 'FA_KEY_API_ACME_DEV');
      expect(entry.apiType, 'openai');
      expect(h.providerChanges, isNotEmpty);
      expect(
        io.out.toString(),
        contains(
          'ext provider acme-main saved: https://api.acme.dev/v1 '
          '(key: FA_KEY_API_ACME_DEV)',
        ),
      );
      await h.exit();
    },
  );

  test(
    'E10: a bare id always reaches the core entry, never the flow',
    () async {
      await _install(env, 'acme');
      final h = await _Harness.boot(
        env,
        io,
        commit: () => _commit([
          {..._setupFlow(), 'id': 'custom'},
        ]),
      );

      // 'custom' is the CORE guided wizard's subcommand: the flow with the
      // same bare id must not shadow it.
      io.sendLine('/provider custom');
      await waitForIt(
        () => io.out.toString().contains('custom provider setup'),
      );
      expect(h.received, isEmpty);
      io.interrupt(); // cancel the core wizard
      await waitForIt(() => io.out.toString().contains('setup cancelled'));

      // The flow is reachable ONLY under its namespaced key.
      io.sendLine('/provider ext:acme:custom');
      await waitForIt(() => io.out.toString().contains('Acme host: '));
      io.interrupt();
      await waitForIt(() => io.out.toString().contains('canceled'));
      expect(h.received, isEmpty);
      await h.exit();
    },
  );

  test('empty answer cancels before submit; nothing persists', () async {
    await _install(env, 'acme');
    final h = await _Harness.boot(
      env,
      io,
      commit: () => _commit([_setupFlow()]),
    );

    io.sendLine('/provider ext:acme:setup');
    await waitForIt(() => io.out.toString().contains('Acme host: '));
    io.sendLine('api.acme.dev');
    await waitForIt(() => io.out.toString().contains('Acme token: '));
    io.sendLine('');
    await waitForIt(() => io.out.toString().contains('canceled'));

    expect(h.received, isEmpty);
    expect(h.store.map, isEmpty);
    expect(h.registry.entries, isEmpty);
    expect(h.providerChanges, isEmpty);
    await h.exit();
  });

  test(
    'submit failure prints a structured error and persists nothing',
    () async {
      await _install(env, 'acme');
      final h =
          await _Harness.boot(env, io, commit: () => _commit([_setupFlow()]))
            ..submitError = 'boom';

      io.sendLine('/provider ext:acme:setup');
      await waitForIt(() => io.out.toString().contains('Acme host: '));
      io.sendLine('api.acme.dev');
      await waitForIt(() => io.out.toString().contains('Acme token: '));
      io.sendLine('sk-acme-1');
      await waitForIt(
        () => io.out.toString().contains('[ext:acme] flow failed: boom'),
      );

      expect(h.received, [
        {'host': 'api.acme.dev', 'token': 'sk-acme-1'},
      ]);
      expect(h.store.map, isEmpty);
      expect(h.registry.entries, isEmpty);
      expect(h.providerChanges, isEmpty);
      await h.exit();
    },
  );

  test('no flows: no extension providers section', () async {
    await _installToolOnly(env, 'plain');
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        homeDir: '/home',
        extRuntimeFactory: (ext) => FakeJsrRuntime('fake')
          ..onGlobal(
            '__extCommit',
            (args) async => {
              'tools': [
                {'name': 'acme_tool', 'description': 'x', 'handle': _handles++},
              ],
              'flows': const <Map<String, Object?>>[],
            },
          ),
        secureKeys: cache,
        envVarValue: (_) => null,
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
    final run = cli.run();
    await waitForIt(
      () => cli.agent.state.tools.any((tool) => tool.name == 'acme_tool'),
    );
    io.sendLine('/provider');
    await waitForIt(() => io.out.toString().contains('supported providers:'));
    expect(io.out.toString(), isNot(contains('extension providers:')));
    io.sendLine('/exit');
    await run;
    io.close();
  });
}
