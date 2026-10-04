// Core-side coverage for the shared compaction host-wiring contract
// (gh-1077, lib/src/compaction/host_wiring.dart). The PR's parity tests
// live on the app side (flutter_app/test/compaction_host_wiring_test.dart,
// AC5), but the CRAP ratchet scores CORE lib/ against the CORE lcov — a
// function exercised only by flutter_app tests lands at 0% coverage and
// fails the pinned threshold. These tests pin the contract's semantics on
// the core side so the app parity suite cannot be the sole coverage
// source.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _main = Model(
  id: 'claude-main',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'http://localhost:1',
  contextWindow: 200000,
  maxTokens: 4096,
);

const _smol = Model(
  id: 'claude-smol',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'http://localhost:1',
  contextWindow: 200000,
  maxTokens: 4096,
);

/// A smol that differs only by provider (same model id) — the distinctness
/// check must catch provider-level drift too.
const _smolOtherProvider = Model(
  id: 'claude-smol',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'http://localhost:1',
  contextWindow: 200000,
  maxTokens: 4096,
);

StreamFunction _neverStream(String kind, String apiKey) {
  return (model, context, {cancelToken}) =>
      throw StateError('no stream expected');
}

ModelRolesResolver _resolverFor(Map<String, List<ModelRef>> roles) {
  return ModelRolesResolver(
    config: ModelRolesConfig(roles: roles),
    secrets: const {
      'ANTHROPIC_API_KEY': 'a-key',
      'OPENAI_API_KEY': 'o-key',
    },
    streamFactory: _neverStream,
  );
}

void _expectSettingsForWindow(CompactionSettings settings, int window) {
  final expected = CompactionSettings.forWindow(window);
  expect(settings.enabled, expected.enabled);
  expect(settings.reserveTokens, expected.reserveTokens);
  expect(settings.keepRecentTokens, expected.keepRecentTokens);
}

void main() {
  group('resolveCompactionHostWiring', () {
    test('uncapped: catalog window drives window and thresholds', () {
      final wiring = resolveCompactionHostWiring(mainModel: _main);
      expect(wiring.window, 200000);
      expect(wiring.conversationWindow, 200000);
      _expectSettingsForWindow(wiring.settings, 200000);
      expect(wiring.smolModel, isNull);
      expect(wiring.enabled, isTrue);
      expect(wiring.maxAttempts, compactionSummarizerMaxAttempts);
      expect(wiring.baseBackoff, compactionSummarizerBaseBackoff);
    });

    test('owner cap below the catalog clamps the window down', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        contextWindowCap: 128000,
      );
      expect(wiring.window, 128000);
      expect(wiring.conversationWindow, 128000);
      _expectSettingsForWindow(wiring.settings, 128000);
    });

    test('owner cap above the catalog raises to the served truth (E2)', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        contextWindowCap: 300000,
      );
      expect(wiring.window, 300000);
    });

    test('null/zero/negative caps leave the catalog window', () {
      for (final cap in [null, 0, -5]) {
        final wiring = resolveCompactionHostWiring(
          mainModel: _main,
          contextWindowCap: cap,
        );
        expect(wiring.window, 200000, reason: 'cap: $cap');
      }
    });

    test('system overhead shrinks the conversation window, not the window',
        () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        systemOverheadTokens: 4000,
      );
      expect(wiring.window, 200000);
      expect(wiring.conversationWindow, 196000);
      _expectSettingsForWindow(wiring.settings, 196000);
    });

    test('overhead larger than the window clamps the conversation to 0',
        () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        systemOverheadTokens: 300000,
      );
      expect(wiring.window, 200000);
      expect(wiring.conversationWindow, 0);
      _expectSettingsForWindow(wiring.settings, 0);
    });

    test('an explicit settings override wins over the scaled default', () {
      const override = CompactionSettings(
        enabled: false,
        reserveTokens: 4096,
        keepRecentTokens: 8192,
      );
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        settingsOverride: override,
      );
      expect(wiring.settings, override);
    });

    test('a smol distinct by id is kept', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        smolModel: _smol,
      );
      expect(wiring.smolModel, same(_smol));
    });

    test('a smol distinct only by provider is kept', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        smolModel: _smolOtherProvider,
      );
      expect(wiring.smolModel, same(_smolOtherProvider));
    });

    test('a smol equal to the main model is normalized to null', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _main,
        smolModel: _main,
      );
      expect(wiring.smolModel, isNull);
    });

    test('enabled defaults to the shared ON constant and can be disabled',
        () {
      expect(
        resolveCompactionHostWiring(mainModel: _main).enabled,
        compactionEnabledByDefault,
      );
      expect(
        resolveCompactionHostWiring(mainModel: _main, enabled: false).enabled,
        isFalse,
      );
    });
  });

  group('resolveCliCompactionWiring', () {
    test('a null resolver keeps the main-model fallback (smol null)', () {
      final wiring = resolveCliCompactionWiring(
        mainModel: _main,
        rolesResolver: null,
        contextWindowCap: null,
      );
      expect(wiring.smolModel, isNull);
      expect(wiring.window, 200000);
    });

    test('a resolver without a smol role keeps the main-model fallback',
        () {
      final wiring = resolveCliCompactionWiring(
        mainModel: _main,
        rolesResolver: _resolverFor(const {}),
        contextWindowCap: null,
      );
      expect(wiring.smolModel, isNull);
    });

    test('a configured smol chain resolves the smol model', () {
      final wiring = resolveCliCompactionWiring(
        mainModel: _main,
        rolesResolver: _resolverFor(const {
          'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
        }),
        contextWindowCap: 128000,
      );
      expect(wiring.smolModel, isNotNull);
      expect(wiring.smolModel!.id, 'claude-smol');
      expect(wiring.window, 128000);
    });

    test('a smol chain resolving to the main model normalizes to null',
        () {
      final wiring = resolveCliCompactionWiring(
        mainModel: _main,
        rolesResolver: _resolverFor(const {
          'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-main')],
        }),
        contextWindowCap: null,
      );
      expect(wiring.smolModel, isNull);
    });

    test('a smol chain with no usable entry throws ConfigException', () {
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'smol': [ModelRef(provider: 'anthropic', modelId: 'x')],
          },
        ),
        secrets: const {}, // every entry skips: no keys
        streamFactory: _neverStream,
      );
      expect(
        () => resolveCliCompactionWiring(
          mainModel: _main,
          rolesResolver: resolver,
          contextWindowCap: null,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('resolveAppContextWindow', () {
    test('a stored window different from the fallback wins (picker/endpoint)',
        () {
      expect(
        resolveAppContextWindow(providerKind: 'google', storedWindow: 264000),
        264000,
      );
    });

    test('a stored value equal to the fallback means "unknown" — catalog '
        'wins', () {
      expect(
        resolveAppContextWindow(providerKind: 'google', storedWindow: 200000),
        1000000,
      );
    });

    test('a null stored window falls through to the catalog', () {
      expect(resolveAppContextWindow(providerKind: 'anthropic'), 200000);
      expect(resolveAppContextWindow(providerKind: 'google'), 1000000);
    });

    test('a non-positive stored window falls through to the catalog', () {
      for (final stored in [0, -100]) {
        expect(
          resolveAppContextWindow(providerKind: 'google', storedWindow: stored),
          1000000,
          reason: 'stored: $stored',
        );
      }
    });

    test('an unknown provider with no stored value pins the 200k fallback '
        '(E1)', () {
      expect(
        resolveAppContextWindow(providerKind: 'totally-custom'),
        fallbackContextWindow,
      );
      expect(fallbackContextWindow, 200000);
    });

    test('a null provider kind pins the fallback', () {
      expect(resolveAppContextWindow(), fallbackContextWindow);
    });
  });

  group('CompactionHostWiring.sameResolutionAs', () {
    CompactionHostWiring wiring({
      int window = 200000,
      int conversationWindow = 200000,
      CompactionSettings? settings,
      Model? smol,
      bool enabled = true,
      int maxAttempts = compactionSummarizerMaxAttempts,
      Duration baseBackoff = compactionSummarizerBaseBackoff,
    }) {
      return CompactionHostWiring(
        window: window,
        conversationWindow: conversationWindow,
        settings:
            settings ??
            const CompactionSettings(
              enabled: true,
              reserveTokens: 16384,
              keepRecentTokens: 20000,
            ),
        smolModel: smol,
        enabled: enabled,
        maxAttempts: maxAttempts,
        baseBackoff: baseBackoff,
      );
    }

    test('identical wirings resolve the same', () {
      final a = wiring();
      expect(a.sameResolutionAs(wiring()), isTrue);
      expect(a.sameResolutionAs(a), isTrue);
    });

    test('window and conversationWindow drift fails the parity', () {
      final base = wiring();
      expect(base.sameResolutionAs(wiring(window: 128000)), isFalse);
      expect(
        base.sameResolutionAs(wiring(conversationWindow: 196000)),
        isFalse,
      );
    });

    test('settings drift (any threshold field) fails the parity', () {
      final base = wiring();
      expect(
        base.sameResolutionAs(
          wiring(
            settings: const CompactionSettings(
              enabled: false,
              reserveTokens: 16384,
              keepRecentTokens: 20000,
            ),
          ),
        ),
        isFalse,
      );
      expect(
        base.sameResolutionAs(
          wiring(
            settings: const CompactionSettings(
              enabled: true,
              reserveTokens: 8192,
              keepRecentTokens: 20000,
            ),
          ),
        ),
        isFalse,
      );
      expect(
        base.sameResolutionAs(
          wiring(
            settings: const CompactionSettings(
              enabled: true,
              reserveTokens: 16384,
              keepRecentTokens: 10000,
            ),
          ),
        ),
        isFalse,
      );
    });

    test('enabled/retry-ladder drift fails the parity', () {
      final base = wiring();
      expect(base.sameResolutionAs(wiring(enabled: false)), isFalse);
      expect(base.sameResolutionAs(wiring(maxAttempts: 5)), isFalse);
      expect(
        base.sameResolutionAs(wiring(baseBackoff: Duration(seconds: 2))),
        isFalse,
      );
    });

    test('smol null-vs-set asymmetry fails the parity; both-null passes',
        () {
      final base = wiring();
      expect(base.sameResolutionAs(wiring(smol: _smol)), isFalse);
      expect(wiring(smol: _smol).sameResolutionAs(base), isFalse);
      expect(wiring().sameResolutionAs(wiring()), isTrue);
    });

    test('smol identity compares by provider+id, not instance', () {
      const sameSmol = Model(
        id: 'claude-smol',
        api: 'anthropic-messages',
        provider: 'anthropic',
        baseUrl: 'http://elsewhere:2',
        contextWindow: 40000,
        maxTokens: 1024,
      );
      expect(
        wiring(smol: _smol).sameResolutionAs(wiring(smol: sameSmol)),
        isTrue,
      );
      const otherId = Model(
        id: 'claude-other',
        api: 'anthropic-messages',
        provider: 'anthropic',
        baseUrl: 'http://localhost:1',
        contextWindow: 200000,
        maxTokens: 4096,
      );
      expect(wiring(smol: _smol).sameResolutionAs(wiring(smol: otherId)),
          isFalse);
      expect(
        wiring(smol: _smol).sameResolutionAs(wiring(smol: _smolOtherProvider)),
        isFalse,
      );
    });
  });
}
