// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part C: the `open_app` pre-flight gate (AC7/AC8/AC10) — gate
/// selection, named outcomes, and the no-fake-success tool contract.
library;

import 'package:fa/apps/app_preflight.dart';
import 'package:fa/apps/open_app_tool.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

Future<void> _seedDemoApp(ExecutionEnv env) async {
  await env.writeFile(
    'apps/demo/manifest.json',
    '{"id":"demo","name":"Demo App"}',
  );
  await env.writeFile(
    'apps/demo/widget.js',
    '(function(){jsr.render({type:"text",data:"hi"});})();',
  );
}

void main() {
  group('runAppPreflight gate selection', () {
    test('app not found fails with a named outcome', () async {
      final env = MemoryExecutionEnv();
      final outcome = await runAppPreflight('missing', env);
      expect(outcome, isA<AppPreflightFailed>());
      expect(outcome!.gate, 'none');
      expect((outcome as AppPreflightFailed).excerpt, contains('not found'));
    });

    test('a red standing test fails the flutter-test gate with the '
        'excerpt (AC8)', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      await env.writeFile(
        'test/apps/demo_test.dart',
        'void main() { expect(1, 2); }',
      );
      final runner = _FakeRunner(
        const FlutterTestResult(passed: false, output: 'EXCERPT: expected 2'),
      );
      final outcome = await runAppPreflight(
        'demo',
        env,
        testRunner: runner,
      );
      expect(outcome, isA<AppPreflightFailed>());
      expect(outcome!.gate, 'flutter-test');
      expect(
        (outcome as AppPreflightFailed).excerpt,
        contains('EXCERPT'),
      );
      expect(runner.ranFor, ['demo']);
    });

    test('a green standing test passes the flutter-test gate', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      await env.writeFile('test/apps/demo_test.dart', 'void main() {}');
      final outcome = await runAppPreflight(
        'demo',
        env,
        testRunner: _FakeRunner(
          const FlutterTestResult(passed: true, output: 'ok'),
        ),
      );
      expect(outcome, isA<AppPreflightPassed>());
      expect(outcome!.gate, 'flutter-test');
    });

    test('no toolchain: a non-bootable host installs NO gate instead of '
        'failing every healthy app', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final outcome = await runAppPreflight(
        'demo',
        env,
        jsEngineBootableOverride: false,
      );
      expect(outcome, isNull);
    });

    test('a bootable host without a runner degrades to the named '
        'smoke-render gate (AC10)', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final outcome = await runAppPreflight(
        'demo',
        env,
        jsEngineBootableOverride: true,
        smokeProbe: (app, env) async =>
            const AppPreflightPassed(gate: 'smoke-render'),
      );
      expect(outcome, isA<AppPreflightPassed>());
      expect(outcome!.gate, 'smoke-render');
    });

    test('a broken manifest fails fast, gate named none (issue #866)', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/broken/manifest.json', '{not json');
      final outcome = await runAppPreflight('broken', env);
      expect(outcome, isA<AppPreflightFailed>());
      expect(outcome!.gate, 'none');
    });
  });

  group('open_app no-fake-success contract (AC7)', () {
    test('a failed gate fails the tool call and never launches', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final launched = <String>[];
      final tool = openAppTool(
        env,
        launcher: (app) => launched.add(app.id),
        preflight: (id) async =>
            const AppPreflightFailed(gate: 'flutter-test', excerpt: 'RED'),
      );
      expect(
        () => tool.execute({'id': 'demo'}, null, null),
        throwsA(
          predicate(
            (e) => '$e'.contains('flutter-test') && '$e'.contains('RED'),
          ),
        ),
      );
      expect(launched, isEmpty, reason: 'a red gate must never launch');
    });

    test('a passed gate launches', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final launched = <String>[];
      final tool = openAppTool(
        env,
        launcher: (app) => launched.add(app.id),
        preflight: (id) async => const AppPreflightPassed(gate: 'smoke'),
      );
      await tool.execute({'id': 'demo'}, null, null);
      expect(launched, ['demo']);
    });

    test('the AgentService default wiring installs the gate on the '
        'registered open_app tool', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final service = _fakeService(env);
      addTearDown(service.dispose);
      service.appLauncher = (app) {};
      final tool = service.toolsForTest
          .where((t) => t.name == openAppToolName)
          .cast<AgentTool>()
          .first;
      // No JS engine on this host + no standing test → the gate is
      // absent (a host-capability skip, never a fake failure).
      final result = await tool.execute({'id': 'demo'}, null, null);
      expect(
        result.content.whereType<TextContent>().map((b) => b.text).join(),
        "Opened app 'Demo App'",
      );
    });
  });
}

class _FakeRunner implements FlutterTestRunner {
  _FakeRunner(this.result);

  final FlutterTestResult result;
  final ranFor = <String>[];

  @override
  Future<FlutterTestResult> runAppTest(String appId) async {
    ranFor.add(appId);
    return result;
  }
}
