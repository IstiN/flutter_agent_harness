// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The service wiring of the yaml sections (issue #1078 AC1-AC5, E1/E3):
/// a full [AgentService.create] against a sandbox home with a real config
/// file — the same parsers the parity guard pins, applied to the live
/// agent. The app-UI stores stay authoritative (E1); yaml fills the gaps.
library;

import 'dart:async';
import 'dart:io';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_config_loader.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late Directory project;

  setUp(() {
    home = Directory.systemTemp.createTempSync('fah-config-home');
    project = Directory.systemTemp.createTempSync('fah-config-project');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
    // The AC5 override is a process global — never leak into other tests.
    providerTimeoutsOverride = null;
  });

  void writeConfig(String body) {
    final dir = Directory('${home.path}/.fah');
    dir.createSync(recursive: true);
    File('${dir.path}/config.yaml').writeAsStringSync(body);
  }

  Future<AgentService> buildService({
    TaskModelsStore? taskModelsStore,
    StreamFunction? streamFunction,
    SessionKeysStore? sessionKeys,
  }) {
    // Role chains resolve API keys through the session-keys snapshot —
    // the app's own credential surface.
    final keys =
        sessionKeys ??
        SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'k',
          'FAH_TEST_ROLE_KEY': 'k',
        });
    return AgentService.create(
      config: AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'test-model',
        baseUrl: 'https://example.test',
        apiKey: 'test-key',
      ),
      env: MemoryExecutionEnv(cwd: project.path),
      taskModelsStore: taskModelsStore,
      streamFunction: streamFunction,
      sessionKeys: keys,
      configHomeDir: home.path,
      watchExternalSessions: false,
    );
  }

  group('AC2 tools + agent.mode', () {
    test(
      'yaml tools resolve under the runtime store; UI toggle wins (E1)',
      () async {
        writeConfig('tools:\n  web_search: false\n  no_such_tool: true\n');
        final service = await buildService();
        addTearDown(service.dispose);

        expect(service.toolAvailability['web_search']!.enabled, isFalse);
        expect(service.toolAvailability['web_search']!.scope, ToolScope.global);
        // Unknown ids are the caller's warning, not a crash: the section
        // still landed (the id simply resolves against no capability).
        expect(service.toolsConfig.tools, isEmpty);

        // E1: an explicit app-UI choice sits ABOVE the yaml scope.
        await service.setToolEnabled('web_search', true);
        expect(service.toolAvailability['web_search']!.enabled, isTrue);
        expect(
          service.toolAvailability['web_search']!.scope,
          ToolScope.runtime,
        );
        // Idempotent re-apply (E3): re-applying is a no-op, still live.
        await service.setToolEnabled('web_search', true);
        expect(service.toolAvailability['web_search']!.enabled, isTrue);
      },
    );

    test(
      'agent.mode: omp demotes to discoverable; pi keeps the 4 base',
      () async {
        writeConfig('agent:\n  mode: pi\n');
        final service = await buildService();
        addTearDown(service.dispose);

        // pi (#679): only the benchmark base stays schema-visible — every
        // other id is discoverable with discovery OFF in pi.
        final visible = service.toolAvailability.entries
            .where((e) => e.value.enabled)
            .map((e) => e.key)
            .toSet();
        expect(visible, containsAll(['read', 'write', 'edit', 'bash']));
      },
    );
  });

  group('AC1 roles', () {
    test(
      'store wins per role; yaml fills the gaps; retry rides along',
      () async {
        writeConfig('''
roles:
  smol:
    - provider: openai-completions
      model: yaml-smol
      apiKeyName: FAH_TEST_ROLE_KEY
  plan:
    - provider: openai-completions
      model: planner
      apiKeyName: FAH_TEST_ROLE_KEY
retry:
  retriesPerEntry: 5
''');
        final store = TaskModelsStore.inMemory({
          'smol': TaskRoleConfig(
            providerKind: 'openai-completions',
            modelId: 'store-smol',
            baseUrl: 'https://example.test',
          ),
        });
        final service = await buildService(taskModelsStore: store);
        addTearDown(service.dispose);

        final resolver = service.taskRolesResolverForTest;
        expect(resolver, isNotNull);
        // The explicit store choice beats the yaml chain (E1).
        final smol = resolver!.resolveRole('smol')!;
        expect(smol.model.id, 'store-smol');
        // yaml-only roles resolve (the gap yaml fills).
        expect(resolver.resolveRole('plan')!.model.id, 'planner');
        // The retry policy came from yaml.
        expect(resolver.config.retry.retriesPerEntry, 5);
      },
    );

    test('yaml-only roles build a resolver when the store is absent', () async {
      writeConfig('roles:\n  smol:\n    - openai-completions/yaml-smol\n');
      final service = await buildService();
      addTearDown(service.dispose);

      final resolver = service.taskRolesResolverForTest;
      expect(resolver, isNotNull);
      expect(resolver!.resolveRole('smol')!.model.id, 'yaml-smol');
    });
  });

  group('AC4 redact', () {
    test(
      'yaml config drives the pipeline; live toggle re-flips it (E3)',
      () async {
        writeConfig('redact:\n  enabled: true\n  blockMode: true\n');
        final service = await buildService();
        addTearDown(service.dispose);

        expect(service.redactionPipelineForTest, isNotNull);
        expect(service.redactionPipelineForTest!.config.blockMode, isTrue);
        // E3: the service-level toggle flips the LIVE pipeline.
        service.setRedactionEnabled(false);
        expect(service.redactionPipelineForTest!.config.enabled, isFalse);
        service.setRedactionEnabled(true);
        expect(service.redactionPipelineForTest!.config.enabled, isTrue);
      },
    );

    test('yaml-disabled redaction attaches no pipeline (CLI parity)', () async {
      writeConfig('redact:\n  enabled: false\n');
      final service = await buildService();
      addTearDown(service.dispose);
      expect(service.redactionPipelineForTest, isNull);
    });

    test(
      're-enabling a yaml-disabled boot rebuilds from boot secrets',
      () async {
        const bootSecret = 'sk-boot-0123456789abcdef';
        writeConfig('redact:\n  enabled: false\n');
        final service = await buildService(
          sessionKeys: SessionKeysStore.inMemory({
            'FAH_BOOT_SECRET_KEY': bootSecret,
          }),
        );
        addTearDown(service.dispose);

        // The yaml-disabled boot attached nothing.
        expect(service.redactionPipelineForTest, isNull);
        // Disabling a pipeline-less service stays a no-op.
        service.setRedactionEnabled(false);
        expect(service.redactionPipelineForTest, isNull);

        // The re-enable rebuilds the layered pipeline SEEDED from the boot
        // secrets snapshot — the exact masking the boot path would have
        // provided (values below SecretRedactor.minValueLength stay out).
        service.setRedactionEnabled(true);
        final pipeline = service.redactionPipelineForTest;
        expect(pipeline, isNotNull);
        expect(pipeline!.config.enabled, isTrue);
        expect(pipeline.registeredSecrets, contains(bootSecret));
        expect(
          pipeline.redact('token $bootSecret end'),
          isNot(contains(bootSecret)),
        );
      },
    );
  });

  group('AC5 providerTimeouts', () {
    test('the CLI global carries the yaml overrides', () async {
      writeConfig(
        'providerTimeouts:\n  connectTimeoutMs: 42000\n'
        '  streamIdleTimeoutMs: 25000\n',
      );
      final service = await buildService();
      addTearDown(service.dispose);
      expect(providerTimeoutsOverride!.connect, const Duration(seconds: 42));
      expect(providerTimeoutsOverride!.streamIdle, const Duration(seconds: 25));
    });

    test('FA_PROVIDER_TIMEOUT_SECONDS folds over the yaml section', () async {
      writeConfig(
        'providerTimeouts:\n  connectTimeoutMs: 42000\n'
        '  streamIdleTimeoutMs: 25000\n',
      );
      final previousEnv = faProviderTimeoutSecondsEnv;
      faProviderTimeoutSecondsEnv = () => '30';
      addTearDown(() => faProviderTimeoutSecondsEnv = previousEnv);
      final service = await buildService();
      addTearDown(service.dispose);
      // The yaml section stands; the env var only replaces the fetch-read
      // leg (issue #1036 precedence: env > config > defaults).
      expect(providerTimeoutsOverride!.connect, const Duration(seconds: 42));
      expect(providerTimeoutsOverride!.streamIdle, const Duration(seconds: 25));
      expect(providerTimeoutsOverride!.fetchRead, const Duration(seconds: 30));
    });

    test('no section clears any previous override', () async {
      providerTimeoutsOverride = ProviderTimeoutsOverride(
        connect: const Duration(seconds: 1),
      );
      final service = await buildService();
      addTearDown(service.dispose);
      expect(providerTimeoutsOverride, isNull);
    });
  });

  group('AC3 ttsr', () {
    test('a rule violation aborts, injects, and retries clean', () async {
      writeConfig('''
ttsr:
  enabled: true
  maxInjectionsPerTurn: 2
  rules:
    - name: no-forbidden
      pattern: 'forbidden'
      body: Never say the forbidden word.
''');
      // First run leaks the forbidden word (aborted mid-stream by the
      // rule), the retry answers clean.
      var calls = 0;
      AssistantMessage msg(Model m, String t) => AssistantMessage(
        content: [TextContent(text: t)],
        api: m.api,
        provider: m.provider,
        model: m.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      );
      AssistantMessageEventStream fakeStream(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        final leaked = calls == 0;
        calls++;
        final text = leaked ? 'the forbidden word' : 'all clean';
        // Emit on timers so the TtsrController observes the delta
        // mid-run (a synchronously-drained stream settles before the
        // abort can land).
        var phase = 0;
        void tick() {
          if (phase == 0) {
            phase++;
            stream.push(StartEvent(partial: msg(model, '')));
            Timer(const Duration(milliseconds: 5), tick);
          } else if (phase == 1) {
            phase++;
            stream.push(
              TextDeltaEvent(
                contentIndex: 0,
                delta: text,
                partial: msg(model, text),
              ),
            );
            Timer(const Duration(milliseconds: 5), tick);
          } else {
            stream.push(
              DoneEvent(reason: StopReason.stop, message: msg(model, text)),
            );
          }
        }

        Timer(Duration.zero, tick);
        return stream;
      }

      final service = await buildService(streamFunction: fakeStream);
      addTearDown(service.dispose);

      await service.sendText('say something');
      // Wait out the abort + inject + retry chain (real timers, short).
      for (var i = 0; i < 100 && (service.isStreaming || calls < 2); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final texts = [
        for (final message in service.agentForTest.state.messages)
          if (message is UserMessage && message.content is String)
            message.content as String,
      ];
      expect(
        texts.any((t) => t.contains('Never say the forbidden word')),
        isTrue,
        reason: 'the rule body must be injected as a user message',
      );
    });
  });
}
