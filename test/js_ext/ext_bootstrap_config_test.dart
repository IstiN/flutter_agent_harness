import 'dart:convert';

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_config.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_install.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

const _projectDir = '/proj';
const _userDir = '/home';

(MemoryExecutionEnv, ExtensionStore) rig() {
  final env = MemoryExecutionEnv();
  return (
    env,
    ExtensionStore(env: env, projectDir: _projectDir, userDir: _userDir),
  );
}

/// A self-consistent plan: files' manifest matches [manifest], main.js body
/// distinguishes versions for drift tests.
ExtInstallPlan samplePlan({String body = 'v1', bool tools = false}) {
  final manifestJson = jsonEncode({
    'name': 'sample',
    'kind': 'cli-extension',
    'version': '1.0.0',
    if (tools) 'capabilities': {'tools': true},
  });
  return ExtInstallPlan(
    name: 'sample',
    files: {'manifest.json': manifestJson, 'main.js': body},
    manifest: ExtensionManifest.fromJson(
      jsonDecode(manifestJson) as Map<String, dynamic>,
    ),
    trustSource: ExtTrustSource.local,
    trustRef: '/local/sample',
  );
}

void main() {
  group('ExtBootstrapConfig.fromYaml (strict)', () {
    test('parses entries with optional pins', () {
      final config = ExtBootstrapConfig.fromYaml('''
extensions:
  - source: gh:owner/repo
    pin: abc123
  - source: catalog:crap-guard
  - source: /abs/or/rel/path
''');
      expect(config.extensions, hasLength(3));
      expect(config.extensions[0].source, 'gh:owner/repo');
      expect(config.extensions[0].pin, 'abc123');
      expect(config.extensions[1].pin, isNull);
      expect(config.extensions[2].source, '/abs/or/rel/path');
    });

    test('empty document and empty section => no entries', () {
      expect(ExtBootstrapConfig.fromYaml('').extensions, isEmpty);
      expect(ExtBootstrapConfig.fromYaml('extensions:').extensions, isEmpty);
    });

    test('unknown top key rejected, naming the key', () {
      expect(
        () => ExtBootstrapConfig.fromYaml('extensions: []\nplugins: []\n'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('plugins'),
          ),
        ),
      );
    });

    test('unknown entry key rejected, naming the key', () {
      expect(
        () => ExtBootstrapConfig.fromYaml(
          'extensions:\n  - source: gh:o/r\n  trust: true\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('trust'),
          ),
        ),
      );
    });

    test('entry without source rejected', () {
      expect(
        () => ExtBootstrapConfig.fromYaml('extensions:\n  - pin: abc\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-string pin rejected, naming the key', () {
      expect(
        () => ExtBootstrapConfig.fromYaml(
          'extensions:\n  - source: gh:o/r\n    pin: 12345\n',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('pin'),
          ),
        ),
      );
    });

    test('non-list extensions rejected', () {
      expect(
        () => ExtBootstrapConfig.fromYaml('extensions: nope\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('broken yaml rejected as ConfigException', () {
      expect(
        () => ExtBootstrapConfig.fromYaml('extensions: [oops\n'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('applyExtBootstrap', () {
    test('first apply installs, second is up-to-date (idempotent)', () async {
      final (env, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: /local/sample\n',
      );

      final first = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(),
        prompt: (_) async => true,
      );
      expect(first, ['ext sample installed']);
      expect((await store.find('sample'))!.trust, isNotNull);

      final second = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(),
      );
      expect(second, ['ext sample up-to-date']);
    });

    test('hash drift reports updated (hash changed)', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: /local/sample\n',
      );
      await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(body: 'v1'),
        prompt: (_) async => true,
      );

      // Same content again => still up-to-date.
      final same = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(body: 'v1'),
      );
      expect(same, ['ext sample up-to-date']);

      final drift = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(body: 'v2'),
      );
      expect(drift, ['ext sample updated (hash changed)']);
    });

    test('planner failure => named FAILED line, session proceeds', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: gh:o/r\n',
      );

      final lines = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => throw StateError('repo unreachable'),
      );
      expect(lines, [
        'ext gh:o/r FAILED: Bad state: repo unreachable (skipped)',
      ]);
    });

    test('strict mode rethrows planner failures', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: gh:o/r\n',
      );
      await expectLater(
        applyExtBootstrap(
          config: config,
          store: store,
          planner: (_) async => throw StateError('repo unreachable'),
          strict: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('denied trust (no prompt) => named FAILED line', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: /local/sample\n',
      );
      final lines = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(),
      );
      expect(lines.single, contains('FAILED: trust required, nothing written'));
      expect(await store.find('sample'), isNull);
    });

    test('prompt approval installs through the bootstrap loop', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: /local/sample\n',
      );
      final lines = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => samplePlan(),
        prompt: (_) async => true,
      );
      expect(lines, ['ext sample installed']);
    });

    test(
      'pin mismatch soft-skips with a named line; strict rethrows',
      () async {
        final (_, store) = rig();
        final config = ExtBootstrapConfig.fromYaml(
          'extensions:\n  - source: /local/sample\n    pin: ff00\n',
        );
        final lines = await applyExtBootstrap(
          config: config,
          store: store,
          planner: (_) async => samplePlan(),
        );
        expect(lines.single, contains('FAILED'));
        expect(lines.single, contains('pinned hash mismatch'));

        await expectLater(
          applyExtBootstrap(
            config: config,
            store: store,
            planner: (_) async => samplePlan(),
            strict: true,
          ),
          throwsA(isA<ExtInstallException>()),
        );
      },
    );

    test('planner returning null => skipped line', () async {
      final (_, store) = rig();
      final config = ExtBootstrapConfig.fromYaml(
        'extensions:\n  - source: catalog:missing\n',
      );
      final lines = await applyExtBootstrap(
        config: config,
        store: store,
        planner: (_) async => null,
      );
      expect(lines, ['ext catalog:missing skipped']);
    });

    test(
      'capability drift without re-approval keeps reporting FAILED',
      () async {
        final (_, store) = rig();
        final config = ExtBootstrapConfig.fromYaml(
          'extensions:\n  - source: /local/sample\n',
        );
        var tools = false;
        await applyExtBootstrap(
          config: config,
          store: store,
          planner: (_) async => samplePlan(tools: tools),
          prompt: (request) async {
            // User approves only the first, capability-less grant.
            return request.previousCapabilities == null;
          },
        );
        tools = true;

        final lines = await applyExtBootstrap(
          config: config,
          store: store,
          planner: (_) async => samplePlan(tools: tools),
          prompt: (request) async => request.previousCapabilities == null,
        );
        expect(lines.single, contains('capability change not approved'));
      },
    );
  });
}
