/// gh-1781 — a provider queue (`FA_PROVIDERS_QUEUE` env, project
/// `.fah/config.yaml` `providersQueue:`, user `~/.fah/config.yaml` one)
/// is a FIRST-CLASS boot source: the headless (`fa -p`) boot pipeline
/// resolves the queue BEFORE the secure-store preload and the legacy
/// single-provider key gate, so a clean environment carrying only the
/// queue (plus its entries' `apiKeyEnv` secrets) boots without
/// `FA_PROVIDER_TYPE`, `FA_PROVIDER_CONFIG`, or `OPENROUTER_API_KEY`.
///
/// The tests replicate the exact boot sequence `bin/fah_runapp.dart` runs
/// (scope resolution → preload → queue runtime → key gate → boot model),
/// the same discipline as `roles_custom_providers_boot_test.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart' show FakeSecureKeyStore;

const _queueJson =
    '[{"provider_type":"zai","provider_config":{'
    '"baseUrl":"https://api.z.ai/api/coding/paas/v4",'
    '"model":"glm-5.3-flash","apiKeyEnv":"MY_CUSTOM_QUEUE_KEY"}}]';

/// The boot pipeline for [env] over a clean saved config, verbatim
/// (gh-1781 boot order): `resolveProviderQueueAtBoot` →
/// `secureKeyPreloadNames(+queueEntries)` → `SecureKeyCache.preload` →
/// `collectQueueSecrets` → `ProviderQueueRuntime.build` →
/// `startupApiKey(queueResolved:)`. Returns the runtime, the resolved
/// legacy key, the boot-diagnostic lines, and the queue warning lines.
Future<
  ({
    ProviderQueueRuntime? runtime,
    String apiKey,
    List<String> bootDiagnostics,
    List<String> queueWarnings,
  })
>
_bootHeadless({
  required String projectDir,
  required String homeDir,
  required Map<String, String> env,
  Map<String, String> store = const {},
}) async {
  final queue = resolveProviderQueueAtBoot(
    projectDir: projectDir,
    homeDir: homeDir,
    env: env,
  );
  final saved = CliConfig();
  final fakeStore = FakeSecureKeyStore()..map.addAll(store);
  final keys = SecureKeyCache(fakeStore);
  final report = await keys.preload(
    secureKeyPreloadNames(saved, baseUrl: null, queueEntries: queue.entries),
  );
  ProviderQueueRuntime? runtime;
  final queueWarnings = <String>[];
  if (queue.entries.isNotEmpty) {
    runtime = ProviderQueueRuntime.build(
      queue,
      secrets: collectQueueSecrets(queue.entries, keys, env: env),
      onBindingWarning: queueWarnings.add,
    );
  }
  final apiKey = startupApiKey(
    'openai-completions',
    keys,
    baseUrl: 'https://openrouter.ai/api/v1',
    customProviders: saved.customProviders,
    defaultRoleResolved: false,
    interactive: false,
    queueResolved: runtime != null,
    env: env,
  );
  final bootDiagnostics = secureKeyBootDiagnostics(
    report: report,
    referencedKeyNames: referencedSecureKeyNames(
      saved,
      queueEntries:
          queue.entries.isNotEmpty && queue.scope != ProviderQueueScope.env
          ? queue.entries
          : const [],
      // The env view the boot resolved through (bin reads
      // Platform.environment at this point — the same view the queue
      // scope and the key gate above used).
      env: env,
    ),
    debug: false,
  );
  return (
    runtime: runtime,
    apiKey: apiKey,
    bootDiagnostics: bootDiagnostics,
    queueWarnings: queueWarnings,
  );
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fahqueueboot'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('IT-queue-only-headless-boot (AC1)', () {
    test('a queue-only environment boots headless with the queue head as '
        'the model — no legacy key anywhere', () async {
      final boot = await _bootHeadless(
        projectDir: tmp.path,
        homeDir: tmp.path,
        env: {
          'FA_PROVIDERS_QUEUE': _queueJson,
          'MY_CUSTOM_QUEUE_KEY': 'secret-123',
        },
      );
      expect(boot.runtime, isNotNull);
      final head = boot.runtime!.streamFunction.currentModel;
      expect(head.id, 'glm-5.3-flash');
      expect(head.provider, 'zai');
      expect(head.baseUrl, 'https://api.z.ai/api/coding/paas/v4');
      // The legacy key gate passed with an EMPTY key (the queue lane owns
      // the stream) — never a ConfigException.
      expect(boot.apiKey, isEmpty);
      expect(boot.bootDiagnostics, isEmpty);
    });

    test('E3: an unkeyed saved provider in ~/.fah/config.yaml does not '
        'poison a valid queue boot', () async {
      Directory('${tmp.path}/.fah').createSync();
      File(
        '${tmp.path}/.fah/config.yaml',
      ).writeAsStringSync('providerKind: openai-completions\n');
      final boot = await _bootHeadless(
        projectDir: tmp.path,
        homeDir: tmp.path,
        env: {
          'FA_PROVIDERS_QUEUE': _queueJson,
          'MY_CUSTOM_QUEUE_KEY': 'secret-123',
        },
      );
      expect(boot.runtime, isNotNull);
      expect(boot.apiKey, isEmpty);
    });

    // gh-1781 review (BLOCKING): the documented canonical queue shape is
    // an env-sourced `apiKeyEnv` (`prompts/skills/self-settings/SKILL.md`,
    // "Provider queue"). A project/user-config queue whose key resolves
    // from the environment is the SAME key-source situation as the
    // env-scope queue — the "resolved NOTHING from the secure store —
    // those providers boot keyless" alarm must stay silent for it too.
    // The E3 test above only covers the env scope, which is why the false
    // alarm on this flow slipped through.
    test('IT: a project-scope queue with an env-only apiKeyEnv prints NO '
        'store boot diagnostics', () async {
      Directory('${tmp.path}/.fah').createSync();
      File('${tmp.path}/.fah/config.yaml').writeAsStringSync('''
providersQueue:
  - provider_type: zai
    provider_config:
      baseUrl: https://api.z.ai/api/coding/paas/v4
      model: glm-5.3-flash
      apiKeyEnv: MY_CUSTOM_QUEUE_KEY
''');
      final boot = await _bootHeadless(
        projectDir: tmp.path,
        homeDir: tmp.path,
        env: {'MY_CUSTOM_QUEUE_KEY': 'secret-123'},
      );
      expect(boot.runtime, isNotNull);
      expect(boot.runtime!.streamFunction.currentModel.id, 'glm-5.3-flash');
      expect(boot.apiKey, isEmpty);
      // The env key resolves and the queue serves — no false "boot
      // keyless" alarm with the wrong "re-enter a key" remediation.
      expect(boot.bootDiagnostics, isEmpty);
    });

    // The guardrail twin: a config-scope queue entry whose key resolves
    // from NEITHER env nor store IS store-referenced and unresolved — the
    // warning must keep firing for it (env-resolved names drop out of the
    // diagnostics set, env-unresolved names stay).
    test('IT: a project-scope queue key absent from env AND store still '
        'warns (store-referenced and unresolved)', () async {
      Directory('${tmp.path}/.fah').createSync();
      File('${tmp.path}/.fah/config.yaml').writeAsStringSync('''
providersQueue:
  - provider_type: zai
    provider_config:
      baseUrl: https://api.z.ai/api/coding/paas/v4
      model: glm-5.3-flash
      apiKeyEnv: STORE_ONLY_QUEUE_KEY
  - provider_type: zai
    provider_config:
      baseUrl: https://api.z.ai/api/coding/paas/v4
      model: glm-5.3-airx
      apiKeyEnv: MY_CUSTOM_QUEUE_KEY
''');
      final boot = await _bootHeadless(
        projectDir: tmp.path,
        homeDir: tmp.path,
        // MY_CUSTOM_QUEUE_KEY resolves from the env; STORE_ONLY_QUEUE_KEY
        // resolves nowhere — entry #0 is skipped (queue warning channel)
        // and its name is the one store-referenced key the diagnostics
        // must still warn about.
        env: {'MY_CUSTOM_QUEUE_KEY': 'secret-123'},
      );
      expect(boot.runtime, isNotNull);
      expect(boot.runtime!.streamFunction.currentModel.id, 'glm-5.3-airx');
      expect(boot.bootDiagnostics, hasLength(1));
      expect(boot.bootDiagnostics.single, allOf(
        contains('1 provider key(s)'),
        contains('resolved NOTHING'),
      ));
    });
  });

  group('IT-queue-head-missing-key-failover (AC2)', () {
    test('a keyless head entry is skipped loudly; entry #1 leads', () async {
      final boot = await _bootHeadless(
        projectDir: tmp.path,
        homeDir: tmp.path,
        env: {
          'FA_PROVIDERS_QUEUE': jsonEncode([
            {
              'provider_type': 'zai',
              'provider_config': {
                'baseUrl': 'https://api.z.ai/api/coding/paas/v4',
                'model': 'glm-5.3-flash',
                'apiKeyEnv': 'MISSING_KEY_1',
              },
            },
            {
              'provider_type': 'zai',
              'provider_config': {
                'baseUrl': 'https://api.z.ai/api/coding/paas/v4',
                'model': 'glm-5.3-airx',
                'apiKeyEnv': 'PRESENT_KEY_2',
              },
            },
          ]),
          'PRESENT_KEY_2': 'present-key-value',
        },
      );
      expect(boot.runtime, isNotNull);
      expect(boot.runtime!.streamFunction.currentModel.id, 'glm-5.3-airx');
      expect(boot.apiKey, isEmpty);
      expect(boot.queueWarnings, hasLength(1));
      expect(
        boot.queueWarnings.single,
        allOf(
          contains('provider queue skipped'),
          contains('zai/glm-5.3-flash'),
          contains('MISSING_KEY_1'),
        ),
      );
    });
  });

  group('IT-queue-all-keys-missing-exit (AC3)', () {
    test('an all-keyless queue fails with the queue error, never the '
        'OpenRouter missing-key error', () async {
      final queue = resolveProviderQueueAtBoot(
        projectDir: tmp.path,
        homeDir: tmp.path,
        env: {
          'FA_PROVIDERS_QUEUE': jsonEncode([
            {
              'provider_type': 'zai',
              'provider_config': {
                'baseUrl': 'https://api.z.ai/api/coding/paas/v4',
                'model': 'glm-5.3-flash',
                'apiKeyEnv': 'MISSING_KEY_1',
              },
            },
          ]),
        },
      );
      final keys = SecureKeyCache(FakeSecureKeyStore());
      await keys.preload(
        secureKeyPreloadNames(
          CliConfig(),
          baseUrl: null,
          queueEntries: queue.entries,
        ),
      );
      // The queue runtime build throws BEFORE the legacy gate would —
      // naming the entry's env var, never OPENROUTER_API_KEY.
      expect(
        () => ProviderQueueRuntime.build(
          queue,
          secrets: collectQueueSecrets(queue.entries, keys, env: const {}),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('the provider queue has no usable entry'),
              contains('MISSING_KEY_1'),
              isNot(contains('OPENROUTER_API_KEY')),
            ),
          ),
        ),
      );
    });
  });

  group('UT-queue-boot-model-notes — boot identity (AC6)', () {
    test('the queue head is the boot model when the launch pinned nothing '
        'of its own', () {
      expect(
        queueOwnsBootModel(
          modelFlag: false,
          providerFlag: false,
          baseUrlFlag: false,
          hasProviderPreconfig: false,
          folderRestoreApplied: false,
        ),
        isTrue,
      );
    });
  });
}
