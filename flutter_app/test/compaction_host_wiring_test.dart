// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1077 — compaction host parity (UT-1 + UT-2, AC3 + AC5):
///
/// - **UT-1 (AC3)**: the app's window resolution picks the provider-catalog
///   window / the effective (capped) window over the pinned fallback
///   constant, for catalog providers whose catalog window differs from the
///   fallback (google 1M) and for one where they coincide (anthropic 200k).
/// - **UT-2 (AC5)**: THE CROSS-HOST REGRESSION GUARD — the compaction
///   wiring built through the CLI path (`resolveCliCompactionWiring` over
///   a roles config) and the app path (`TaskModelsStore` →
///   [StoreBackedRolesMap] → the same resolver semantics) over the SAME
///   config inputs resolves semantic equals (window, reserve, summarizer
///   chain, retry policy, enabled flag). Drift in either path fails here —
///   a red UT-2 blocks merge even when all IT/E2E are green.
/// - **Edges**: E1 (unknown provider → pinned fallback, value asserted),
///   E2 (owner cap above catalog honored), E5 (small on-device windows
///   still trigger before the provider's hard limit).
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/screens/providers_section.dart' show agentConfigFrom;
import 'package:fa_ui/fa_ui.dart'
    show FaChatModelConfig, TaskModelsStore, TaskRole, TaskRoleConfig;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pinned fallback constant (gh-1077 pins its value and definition
/// site: `lib/src/providers/models_endpoint.dart`).
const fallbackWindow = fallbackContextWindow;

Model _mainModel({int contextWindow = 200000}) => Model(
  id: 'claude-sonnet-x',
  name: 'claude-sonnet-x',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.example',
  contextWindow: contextWindow,
  maxTokens: 16384,
  input: const ['text'],
);

/// The smol chain entry both host paths share in the parity inputs.
const smolRef = ModelRef(
  provider: 'openai-completions',
  modelId: 'cheap-fast-model',
  apiKeyName: 'SMOL_KEY',
  baseUrl: 'https://smol-endpoint.invalid/v1',
);

void main() {
  group('UT-1 — app window resolution (AC3)', () {
    test('catalog window beats the fallback where they differ (google 1M)', () {
      expect(resolveAppContextWindow(providerKind: 'google'), 1000000);
      expect(fallbackWindow, 200000, reason: 'pinned fallback value');
    });

    test(
      'anthropic resolves through the catalog too (200k, equals fallback)',
      () {
        expect(resolveAppContextWindow(providerKind: 'anthropic'), 200000);
      },
    );

    test('endpoint/picker-stored window wins over the catalog', () {
      expect(
        resolveAppContextWindow(providerKind: 'google', storedWindow: 264000),
        264000,
      );
    });

    test('a stored value equal to the fallback constant means "unknown"', () {
      // Pickers and persisted configs default to the constant — it must
      // not suppress the catalog lookup.
      expect(
        resolveAppContextWindow(providerKind: 'google', storedWindow: 200000),
        1000000,
      );
    });

    test('E1: unknown/custom provider → the pinned fallback (200000)', () {
      expect(resolveAppContextWindow(providerKind: 'totally-custom'), 200000);
      expect(resolveAppContextWindow(providerKind: null), 200000);
    });

    test(
      'the threshold computes from the effective window, not the fallback',
      () {
        // The compaction trigger for a google-kind connection: 1M window,
        // reserve 16384 → trips at 1000000-16384, not at 200000-16384.
        final wiring = resolveCompactionHostWiring(
          mainModel: _mainModel(
            contextWindow: resolveAppContextWindow(providerKind: 'google'),
          ),
        );
        expect(wiring.window, 1000000);
        expect(wiring.conversationWindow, 1000000);
        expect(wiring.settings.reserveTokens, 16384);
        expect(
          wiring.conversationWindow - wiring.settings.reserveTokens,
          1000000 - 16384,
        );
      },
    );

    test('E2: owner cap above the catalog raises the effective window', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _mainModel(contextWindow: 200000),
        contextWindowCap: 1000000,
      );
      expect(wiring.window, 1000000);
      // …and below it clamps down.
      final clamped = resolveCompactionHostWiring(
        mainModel: _mainModel(contextWindow: 200000),
        contextWindowCap: 64000,
      );
      expect(clamped.window, 64000);
      // The reserve scales with the (capped) window: a quarter of 64k.
      expect(clamped.settings.reserveTokens, 16000);
    });

    test(
      'E5: small on-device windows keep the trigger under the hard limit',
      () {
        // An 8k WebLLM-style preset with a real overhead (system prompt +
        // tool instructions): the conversation window shrinks, the reserve
        // scales with it, and the trigger stays below the provider's 8192.
        const overhead = 2000;
        final wiring = resolveCompactionHostWiring(
          mainModel: _mainModel(contextWindow: 8192),
          systemOverheadTokens: overhead,
        );
        expect(wiring.conversationWindow, 8192 - overhead);
        expect(wiring.settings.reserveTokens, lessThan(8192 ~/ 4));
        expect(
          wiring.conversationWindow - wiring.settings.reserveTokens,
          lessThan(8192),
        );
      },
    );
  });

  group('UT-2 — CLI-vs-app wiring parity (AC5, merge-blocking)', () {
    final secrets = {'SMOL_KEY': 'smol-secret'};

    /// The CLI path: roles config as the CLI writes/reads it.
    ModelRolesResolver cliResolver() => ModelRolesResolver(
      config: ModelRolesConfig(
        roles: {
          'smol': [smolRef],
        },
      ),
      secrets: secrets,
    );

    /// The app path: the SAME config expressed as the app's store override,
    /// mapped through [StoreBackedRolesMap] (the documented stores → roles
    /// mapping).
    ModelRolesResolver appResolver() {
      final store = TaskModelsStore.inMemory({
        TaskRole.smol: TaskRoleConfig(
          providerKind: smolRef.provider,
          baseUrl: smolRef.baseUrl!,
          modelId: smolRef.modelId,
          apiKeyName: smolRef.apiKeyName,
        ),
      });
      return ModelRolesResolver(
        config: ModelRolesConfig(roles: StoreBackedRolesMap(store)),
        secrets: secrets,
      );
    }

    test('identical inputs resolve semantic equals (smol configured)', () {
      for (final cap in [null, 64000, 1000000]) {
        final cli = resolveCliCompactionWiring(
          mainModel: _mainModel(),
          rolesResolver: cliResolver(),
          contextWindowCap: cap,
        );
        final app = resolveCompactionHostWiring(
          mainModel: _mainModel(),
          smolModel: appResolver().resolveRole(smolModelRole)?.model,
          contextWindowCap: cap,
        );
        expect(
          cli.sameResolutionAs(app),
          isTrue,
          reason: 'cap=$cap: CLI and app wiring drifted',
        );
        // And the summarizer chain really is the smol entry, not main.
        expect(cli.smolModel, isNotNull);
        expect(cli.smolModel!.id, 'cheap-fast-model');
      }
    });

    /// The app path with an EMPTY store (no overrides at all).
    ModelRolesResolver appResolverNoSmol() => ModelRolesResolver(
      config: ModelRolesConfig(
        roles: StoreBackedRolesMap(TaskModelsStore.inMemory()),
      ),
      secrets: secrets,
    );

    test('no smol configured: both hosts fall back to the main model', () {
      final cli = resolveCliCompactionWiring(
        mainModel: _mainModel(),
        rolesResolver: ModelRolesResolver(
          config: ModelRolesConfig(roles: const {}),
          secrets: secrets,
        ),
        contextWindowCap: null,
      );
      final app = resolveCompactionHostWiring(
        mainModel: _mainModel(),
        smolModel: appResolverNoSmol().resolveRole(smolModelRole)?.model,
        contextWindowCap: null,
      );
      expect(cli.smolModel, isNull);
      expect(cli.sameResolutionAs(app), isTrue);
    });

    test('smol equal to main normalizes to main-only on BOTH paths', () {
      final sameRef = ModelRef(
        provider: 'anthropic',
        modelId: 'claude-sonnet-x',
        apiKeyName: 'ANTHROPIC_API_KEY',
      );
      final cli = resolveCliCompactionWiring(
        mainModel: _mainModel(),
        rolesResolver: ModelRolesResolver(
          config: ModelRolesConfig(
            roles: {
              'smol': [sameRef],
            },
          ),
          secrets: const {'ANTHROPIC_API_KEY': 'k'},
        ),
        contextWindowCap: null,
      );
      final app = resolveCompactionHostWiring(
        mainModel: _mainModel(),
        smolModel: Model(
          id: 'claude-sonnet-x',
          name: 'claude-sonnet-x',
          api: 'anthropic-messages',
          provider: 'anthropic',
          baseUrl: 'https://api.anthropic.example',
          contextWindow: 200000,
          maxTokens: 16384,
          input: const ['text'],
        ),
        contextWindowCap: null,
      );
      expect(cli.smolModel, isNull, reason: 'smol == main → single attempt');
      expect(cli.sameResolutionAs(app), isTrue);
    });

    test('shared retry ladder and enable flag on both paths', () {
      final cli = resolveCliCompactionWiring(
        mainModel: _mainModel(),
        rolesResolver: cliResolver(),
        contextWindowCap: null,
      );
      expect(cli.enabled, compactionEnabledByDefault);
      expect(cli.maxAttempts, compactionSummarizerMaxAttempts);
      expect(cli.baseBackoff, compactionSummarizerBaseBackoff);
      expect(cli.settings.enabled, isTrue);
    });
  });

  group('UT-1 — the AgentConfig mapping applies the window rule', () {
    test('agentConfigFrom resolves catalog windows for picker configs', () {
      // A picker config whose window was unknown (the fallback constant):
      // the mapping resolves the catalog window for the kind.
      final config = agentConfigFrom(
        const FaChatModelConfig(
          providerKind: 'google',
          modelId: 'gemini-x',
          baseUrl: 'https://generativelanguage.example',
          apiKey: 'k',
        ),
      );
      expect(config.contextWindow, 1000000);

      // An endpoint-reported window (≠ the fallback constant) is kept.
      final reported = agentConfigFrom(
        FaChatModelConfig(
          providerKind: 'openai-completions',
          modelId: 'm',
          baseUrl: 'https://endpoint.example/v1',
          apiKey: 'k',
          contextWindow: 264000,
        ),
      );
      expect(reported.contextWindow, 264000);
    });
  });
}
