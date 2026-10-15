/// Issue #1552 — the boot path with the user's verbatim config shape (the
/// bycom.by report): a `customProviders:` entry named `aiai` referenced by
/// name from every roles chain.
///
/// - **IT-1 (AC1)**: preload set → secrets snapshot → resolver — the exact
///   boot sequence `bin/fah_runapp.dart` runs — resolves every role with
///   no warning and no drop, for the explicit-`apiKeyName` spelling the
///   user wrote AND the entry-default spellings (entry pin, endpoint slot).
/// - **AC4**: the roles-drop warning surfaces in the notice stream, not
///   stderr only.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart' show FakeCliIO, FakeSecureKeyStore;

const _roles = ['default', 'smol', 'slow', 'plan', 'subagent'];

CustomProviderEntry _bycom({String? keyName = 'AIAI_API_KEY'}) =>
    CustomProviderEntry(
      name: 'aiai',
      apiType: 'openai',
      baseUrl: 'https://api.bycom.by/v1',
      modelId: 'glm-4.6',
      keyName: keyName,
    );

StreamFunction _neverStream(String kind, String apiKey) =>
    (model, context, {cancelToken}) => throw StateError('no stream expected');

/// The boot key pipeline for [roles] over [saved], verbatim:
/// `secureKeyPreloadNames` → `SecureKeyCache.preload` →
/// `collectRoleSecrets` → `ModelRolesResolver`.
Future<ModelRolesResolver> _bootResolver(
  CliConfig saved,
  ModelRolesConfig roles, {
  Map<String, String> env = const {},
  Map<String, String> store = const {},
}) async {
  final fakeStore = FakeSecureKeyStore()..map.addAll(store);
  final keys = SecureKeyCache(fakeStore);
  await keys.preload(secureKeyPreloadNames(saved, baseUrl: saved.baseUrl));
  final secrets = collectRoleSecrets(
    roles,
    keys,
    env: env,
    customProviders: saved.customProviders,
  );
  return ModelRolesResolver(
    config: roles,
    secrets: secrets,
    customProviders: saved.customProviders,
    streamFactory: _neverStream,
  );
}

void main() {
  group('IT-1 — boot path with the bycom fixture (AC1)', () {
    test('explicit apiKeyName refs resolve every role from the env', () async {
      final entry = _bycom();
      final roles = ModelRolesConfig(
        roles: {
          for (final role in _roles)
            role: [
              ModelRef(
                provider: 'aiai',
                modelId: 'glm-4.6',
                apiKeyName: 'AIAI_API_KEY',
              ),
            ],
        },
      );
      final saved = CliConfig(customProviders: [entry], modelRoles: roles);
      final resolver = await _bootResolver(
        saved,
        roles,
        env: const {'AIAI_API_KEY': 'k'},
      );
      for (final role in _roles) {
        final resolved = resolver.resolveRole(role);
        if (resolved == null) fail('role $role did not resolve');
        expect(resolved.model.provider, 'openai', reason: role);
        expect(resolved.model.baseUrl, 'https://api.bycom.by/v1', reason: role);
      }
      expect(resolver.skippedEntries.values.expand((s) => s), isEmpty);
    });

    test('a bare ref picks the ENTRY-pinned key from the store', () async {
      final entry = _bycom();
      final roles = ModelRolesConfig(
        roles: {
          for (final role in _roles)
            role: [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
        },
      );
      final saved = CliConfig(customProviders: [entry], modelRoles: roles);
      final resolver = await _bootResolver(
        saved,
        roles,
        store: const {'AIAI_API_KEY': 'stored'},
      );
      for (final role in _roles) {
        expect(resolver.resolveRole(role), isNotNull, reason: role);
      }
      expect(
        resolver.chainFor('default')!.single.keyRing.baseName,
        'AIAI_API_KEY',
        reason: 'the entry pin must ride the secrets snapshot',
      );
    });

    test(
      'a keyless entry picks the endpoint-scoped slot from the store',
      () async {
        final entry = _bycom(keyName: null);
        final roles = ModelRolesConfig(
          roles: {
            for (final role in _roles)
              role: [ModelRef(provider: 'aiai', modelId: 'glm-4.6')],
          },
        );
        final saved = CliConfig(customProviders: [entry], modelRoles: roles);
        final resolver = await _bootResolver(
          saved,
          roles,
          store: const {'FA_KEY_API_BYCOM_BY': 'k'},
        );
        for (final role in _roles) {
          expect(resolver.resolveRole(role), isNotNull, reason: role);
        }
        expect(
          resolver.chainFor('default')!.single.keyRing.baseName,
          'FA_KEY_API_BYCOM_BY',
          reason: 'issue #40: the endpoint-scoped slot serves custom endpoints',
        );
      },
    );
  });

  group('AC4 — the roles-drop warning reaches the notice stream', () {
    test('line mode prints the configured drop notice', () async {
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'placeholder',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'unused',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          rolesDropNotice:
              'warning: model roles config is unusable (role "default" has '
              'no usable chain entry) — falling back to the configured '
              'single provider/model',
          envVarIsSet: (_) => false,
        ),
        io: io,
      );
      final run = cli.run();
      try {
        var printed = false;
        for (var i = 0; i < 2000 && !printed; i++) {
          printed = io.out.toString().contains(
            'model roles config is unusable',
          );
          if (!printed) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        expect(
          printed,
          isTrue,
          reason:
              'the drop notice must reach the IO '
              'stream (line mode), never stderr only',
        );
      } finally {
        io.sendLine('/exit');
        await run;
        await io.close();
      }
    });
  });
}
