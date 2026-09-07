// Deterministic unit tests for the app extension service (contract section
// 14, app wave): store -> load -> tools/hooks wiring, driven entirely through
// FakeJsrRuntime — no real JS engine involved.
import 'dart:convert';

import 'package:fa/services/ext/app_extension_service.dart';
import 'package:fa/services/ext/web_worker_ext_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';

Future<void> _seedExt(
  MemoryExecutionEnv env,
  String name, {
  Map<String, dynamic> capabilities = const {},
  List<String>? platforms,
  bool trusted = true,
  String scope = 'project',
}) async {
  final root = scope == 'project' ? '/proj/.fah/js-ext' : '/user/.fah/js-ext';
  final manifest = <String, dynamic>{
    'name': name,
    'version': '1.0.0',
    'platforms': ?platforms,
    'capabilities': capabilities,
  };
  (await env.writeFile(
    '$root/$name/manifest.json',
    jsonEncode(manifest),
  )).getOrThrow();
  (await env.writeFile('$root/$name/main.js', '// main: $name')).getOrThrow();
  if (trusted) {
    (await env.writeFile(
      '$root/$name/trust.json',
      jsonEncode(
        TrustRecord(
          source: ExtTrustSource.local,
          sourceRef: '$root/$name',
          contentSha256: 'f' * 64,
          capabilities: const {},
          grantedAt: DateTime.utc(2026),
        ).toJson(),
      ),
    )).getOrThrow();
  }
}

/// Per-extension fake engines with a scripted commit payload and an invoke
/// recorder.
final class _Engines {
  _Engines(this.commits);

  final Map<String, Map<String, dynamic>> commits;
  final Map<String, FakeJsrRuntime> byExt = {};
  final List<(String ext, int handle, Object? payload)> invocations = [];

  JsrRuntime factory(StoredExtension ext) {
    final runtime = FakeJsrRuntime('fake');
    byExt[ext.name] = runtime;
    runtime.onGlobal('__extCommit', (_) async => commits[ext.name]);
    runtime.onGlobal('__extInvoke', (args) async {
      invocations.add((
        ext.name,
        args.first as int,
        args.length > 1 ? args[1] : null,
      ));
      return null;
    });
    return runtime;
  }
}

Map<String, dynamic> _commit({
  required String toolName,
  int toolHandle = 1,
  String? hookEvent,
  int hookHandle = 2,
}) => {
  'tools': [
    {
      'name': toolName,
      'description': 'd',
      'parameters': <String, dynamic>{},
      'tier': 'read',
      'handle': toolHandle,
    },
  ],
  'hooks': [
    if (hookEvent != null) {'event': hookEvent, 'handle': hookHandle},
  ],
  'slash': const [],
  'flows': const [],
};

void main() {
  test('WebWorkerExtRuntime is unavailable off web', () {
    expect(
      () => WebWorkerExtRuntime(),
      throwsA(
        isA<ExtEngineUnavailableException>().having(
          (e) => e.reason,
          'reason',
          'web extension engine requires a web build',
        ),
      ),
    );
  });

  test(
    'loads trusted extension into tools/hooks; untrusted is skipped',
    () async {
      final env = MemoryExecutionEnv(cwd: '/proj');
      await _seedExt(
        env,
        'greeter',
        capabilities: {
          'tools': true,
          'hooks': ['onSessionEnd'],
        },
      );
      await _seedExt(
        env,
        'sneaky',
        trusted: false,
      ); // no trust.json => tombstone
      final engines = _Engines({
        'greeter': _commit(toolName: 'ext_greet', hookEvent: 'onSessionEnd'),
      });
      final service = AppExtensionService(
        env: env,
        runtimeFactory: engines.factory,
      );

      final report = await service.load(platform: ExtPlatformTag.ios);

      expect(report.loaded, ['greeter']);
      expect(report.skipped['sneaky'], 'untrusted');
      expect(report.errors, isEmpty);
      expect(service.tools.map((tool) => tool.name), ['ext_greet']);
      expect(service.hooksByExtension, {
        'greeter': {ExtHookEvent.sessionEnd},
      });
      // sessionEnd fires the extension hook through the engine seam.
      await service.sessionEnd();
      expect(engines.invocations, hasLength(1));
      expect(engines.invocations.first.$1, 'greeter');
      expect(engines.invocations.first.$2, 2); // onSessionEnd handle

      await service.dispose();
      expect(engines.byExt['greeter']!.disposed, isTrue);
    },
  );

  test('platform-incompatible extensions are filtered by the store', () async {
    final env = MemoryExecutionEnv(cwd: '/proj');
    await _seedExt(
      env,
      'cli-only',
      platforms: ['cli'],
      capabilities: {'tools': true},
    );
    final engines = _Engines({'cli-only': _commit(toolName: 'ext_cli')});
    final service = AppExtensionService(
      env: env,
      runtimeFactory: engines.factory,
    );

    final report = await service.load(platform: ExtPlatformTag.ios);

    // The store pre-filters, so the extension is absent everywhere.
    expect(report.loaded, isEmpty);
    expect(report.skipped, isEmpty);
    expect(report.errors, isEmpty);
    expect(service.tools, isEmpty);

    // The same extension loads when the platform matches.
    final matching = await service.load(platform: ExtPlatformTag.cli);
    expect(matching.loaded, ['cli-only']);
    expect(service.tools.map((tool) => tool.name), ['ext_cli']);

    await service.dispose();
  });

  test('bootstrap is send-message transport + core', () async {
    final env = MemoryExecutionEnv(cwd: '/proj');
    await _seedExt(env, 'greeter', capabilities: {'tools': true});
    final engines = _Engines({'greeter': _commit(toolName: 'ext_greet')});
    final service = AppExtensionService(
      env: env,
      runtimeFactory: engines.factory,
    );

    await service.load(platform: ExtPlatformTag.ios);

    expect(
      engines.byExt['greeter']!.lastBootstrapJs,
      AppExtensionService.kExtBootstrapJs,
    );
    expect(
      AppExtensionService.kExtBootstrapJs,
      contains("sendMessage('__ext_host'"),
    );
    await service.dispose();
  });

  test('userDir param roots the user scope; project shadows user', () async {
    final env = MemoryExecutionEnv(cwd: '/proj');
    // Same extension name in both scopes; project wins.
    await _seedExt(env, 'dup', capabilities: {'tools': true});
    await _seedExt(env, 'dup', scope: 'user', capabilities: {'tools': true});
    await _seedExt(
      env,
      'user-only',
      scope: 'user',
      capabilities: {'tools': true},
    );
    final engines = _Engines({
      'dup': _commit(toolName: 'ext_dup'),
      'user-only': _commit(toolName: 'ext_user'),
    });
    final service = AppExtensionService(
      env: env,
      userDir: '/user',
      runtimeFactory: engines.factory,
    );

    expect(service.store.userDir, '/user');
    final report = await service.load(platform: ExtPlatformTag.ios);
    expect(report.loaded, ['dup', 'user-only']);
    // The winning 'dup' came from the project scope.
    final dup = await service.store.find('dup');
    expect(dup!.scope, ExtStoreScope.project);

    await service.dispose();
  });

  test('platformForDevice maps defaultTargetPlatform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(platformForDevice(), ExtPlatformTag.ios);

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(platformForDevice(), ExtPlatformTag.macos);

    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    expect(platformForDevice(), ExtPlatformTag.android);
  });
}
