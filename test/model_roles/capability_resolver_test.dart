// gh-1426 UT-1/UT-2: the layered capability resolver — precedence over the
// five layers (user override > role slot > endpoint truth > shared catalog >
// global clamp), per-field, fixture-table driven, no IO.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

YamlMap _yaml(String source) => loadYaml(source) as YamlMap;

const _zaiSpec = ProviderSpec(
  name: 'zai',
  kind: 'zai',
  api: 'openai-completions',
  defaultBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
  apiKeyEnvNames: ['ZAI_API_KEY'],
  contextWindow: 200000,
  maxTokens: 16384,
);

EffectiveCaps _resolve({
  ModelCapabilityOverride? override,
  String? roleThinkingLevel,
  int? roleContextWindow,
  int? roleMaxTokens,
  int? endpointContextWindow,
  int? endpointMaxTokens,
  ProviderSpec? spec = _zaiSpec,
  int? remoteCatalogContextWindow,
  String? api = 'openai-completions',
  bool reasoning = true,
  int? contextWindowCap,
}) {
  return resolveModelCapabilities(
    provider: 'zai',
    modelId: 'glm-5.3-flash',
    override: override,
    roleThinkingLevel: roleThinkingLevel,
    roleContextWindow: roleContextWindow,
    roleMaxTokens: roleMaxTokens,
    endpointContextWindow: endpointContextWindow,
    endpointMaxTokens: endpointMaxTokens,
    spec: spec,
    remoteCatalogContextWindow: remoteCatalogContextWindow,
    api: api,
    reasoning: reasoning,
    contextWindowCap: contextWindowCap,
  );
}

void main() {
  group('resolveModelCapabilities — layer precedence (AC1)', () {
    test('all layers absent → catalog spec defaults', () {
      final caps = _resolve();
      expect(caps.contextWindow, 200000);
      expect(caps.maxTokens, 16384);
      expect(caps.thinkingLevel, isNull);
      expect(caps.omitMaxOutputTokens, isFalse);
      expect(caps.notes, isEmpty);
    });

    test('override beats every layer per field', () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(
          contextWindow: 400000,
          maxTokens: 65536,
          thinkingLevel: 'high',
        ),
        roleContextWindow: 1000,
        roleMaxTokens: 2000,
        roleThinkingLevel: 'low',
        endpointContextWindow: 300000,
        endpointMaxTokens: 32000,
        remoteCatalogContextWindow: 250000,
        contextWindowCap: 150000,
      );
      // The global cap replaces the window LAST (#729 semantics), but the
      // override won the pre-cap resolution and the cap is lower — the cap
      // clamps down as today.
      expect(caps.contextWindow, 150000);
      expect(caps.maxTokens, 65536);
      expect(caps.thinkingLevel, 'high');
    });

    test('override raises the window above the cap (raise direction kept)',
        () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(contextWindow: 1000000),
        contextWindowCap: 500000,
      );
      // #729: the cap REPLACES the window when set — a cap above the
      // resolved window RAISES the effective window to the served truth.
      expect(caps.contextWindow, 500000);
    });

    test('role slot beats endpoint truth and catalog', () {
      final caps = _resolve(
        roleContextWindow: 128000,
        roleMaxTokens: 4096,
        roleThinkingLevel: 'medium',
        endpointContextWindow: 300000,
        endpointMaxTokens: 32000,
        remoteCatalogContextWindow: 250000,
      );
      expect(caps.contextWindow, 128000);
      expect(caps.maxTokens, 4096);
      expect(caps.thinkingLevel, 'medium');
    });

    test('endpoint truth beats shared catalog per field', () {
      final caps = _resolve(
        endpointContextWindow: 300000,
        endpointMaxTokens: 32000,
        remoteCatalogContextWindow: 250000,
      );
      expect(caps.contextWindow, 300000);
      expect(caps.maxTokens, 32000);
    });

    test('remote catalog window fills the gap the endpoint left', () {
      final caps = _resolve(
        endpointMaxTokens: 32000,
        remoteCatalogContextWindow: 250000,
      );
      expect(caps.contextWindow, 250000);
      expect(caps.maxTokens, 32000);
    });

    test('per-field independence: an override sets ONLY its own fields', () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(maxTokens: 65536),
        endpointContextWindow: 300000,
        endpointMaxTokens: 32000,
      );
      // maxTokens: override wins; contextWindow: no override value →
      // endpoint truth applies.
      expect(caps.maxTokens, 65536);
      expect(caps.contextWindow, 300000);
    });

    test('no spec and no endpoint → documented unknown-model defaults', () {
      final caps = _resolve(
        spec: null,
        api: 'openai-completions',
        remoteCatalogContextWindow: null,
      );
      expect(caps.contextWindow, unknownModelContextWindow);
      expect(caps.maxTokens, unknownModelMaxTokens);
    });

    test('the fixture table drives every layer × set/unset combination', () {
      // 5 layers × set/unset = 32 combinations; the fixture table asserts
      // the winner for each field under every combination (no IO).
      const contexts = [1000, 200000, 300000, 400000, 500000];
      for (var mask = 0; mask < 32; mask++) {
        final caps = _resolve(
          override: mask & 1 != 0
              ? const ModelCapabilityOverride(contextWindow: 400000)
              : null,
          roleContextWindow: mask & 2 != 0 ? 300000 : null,
          endpointContextWindow: mask & 4 != 0 ? 250000 : null,
          remoteCatalogContextWindow: mask & 8 != 0 ? 220000 : null,
          contextWindowCap: mask & 16 != 0 ? 180000 : null,
        );
        // Pre-cap winner: first set layer in override > role > endpoint >
        // remote catalog > spec, then the cap replaces the window when set.
        final preCap = mask & 1 != 0
            ? 400000
            : mask & 2 != 0
            ? 300000
            : mask & 4 != 0
            ? 250000
            : mask & 8 != 0
            ? 220000
            : 200000;
        final expected = mask & 16 != 0 ? 180000 : preCap;
        expect(
          caps.contextWindow,
          expected,
          reason: 'layer mask $mask (contexts=$contexts)',
        );
      }
    });
  });

  group('resolveModelCapabilities — global clamp layer (#729 semantics)', () {
    test('cap clamps down', () {
      final caps = _resolve(contextWindowCap: 100000);
      expect(caps.contextWindow, 100000);
    });

    test('cap raises to served truth', () {
      final caps = _resolve(contextWindowCap: 900000);
      expect(caps.contextWindow, 900000);
    });

    test('no cap leaves the window untouched', () {
      expect(_resolve().contextWindow, 200000);
    });
  });

  group('resolveModelCapabilities — thinking gating (AC6/E3)', () {
    test('a pin on a reasoning:false model is gated with a loud note', () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(thinkingLevel: 'high'),
        reasoning: false,
      );
      expect(caps.thinkingLevel, isNull);
      expect(caps.notes, hasLength(1));
      expect(caps.notes.first, contains('glm-5.3-flash'));
      expect(caps.notes.first, contains('thinking'));
    });

    test('a role-slot pin on a reasoning:false model is gated too', () {
      final caps = _resolve(roleThinkingLevel: 'low', reasoning: false);
      expect(caps.thinkingLevel, isNull);
      expect(caps.notes, isNotEmpty);
    });

    test('reasoning models keep the pin, no note', () {
      // Levels ride verbatim (the xhigh/max fold happens at config
      // parse); a parse-built override already carries the folded rung.
      final caps = _resolve(
        override: ModelCapabilityOverride.fromYaml(
          'zai',
          'glm-5.3-flash',
          _yaml('thinkingLevel: max'),
        ),
      );
      expect(caps.thinkingLevel, 'high');
      expect(caps.notes, isEmpty);
    });

    test('the gate never fires without a pin', () {
      final caps = _resolve(reasoning: false);
      expect(caps.thinkingLevel, isNull);
      expect(caps.notes, isEmpty);
    });
  });

  group('resolveModelCapabilities — divergence notes (E1/E4)', () {
    test('an override contradicting endpoint truth names the divergence',
        () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(contextWindow: 400000),
        endpointContextWindow: 300000,
      );
      expect(caps.contextWindow, 400000); // override wins
      expect(caps.notes, hasLength(1));
      expect(caps.notes.first, contains('endpoint'));
      expect(caps.notes.first, contains('400000'));
      expect(caps.notes.first, contains('300000'));
    });

    test('an agreeing override raises no note', () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(contextWindow: 300000),
        endpointContextWindow: 300000,
      );
      expect(caps.notes, isEmpty);
    });

    test('an override for a model absent from every catalog is kept (E4)',
        () {
      final caps = _resolve(
        spec: null,
        remoteCatalogContextWindow: null,
        override: const ModelCapabilityOverride(maxTokens: 65536),
      );
      expect(caps.maxTokens, 65536);
      expect(caps.contextWindow, unknownModelContextWindow);
      expect(caps.notes.any((n) => n.contains('no catalog entry')), isTrue);
    });
  });

  group('resolveModelCapabilities — boundary floors (UT-1)', () {
    test('a programmatically small override window floors at the reserve',
        () {
      // Parse rejects values below the floor loudly; the resolver's floor
      // is the safety net for non-yaml construction paths.
      final caps = _resolve(
        override: const ModelCapabilityOverride(contextWindow: 100),
      );
      expect(caps.contextWindow, minOverrideContextWindow);
    });

    test('a programmatically small override maxTokens floors at the answer',
        () {
      final caps = _resolve(
        override: const ModelCapabilityOverride(maxTokens: 10),
      );
      expect(caps.maxTokens, minOverrideMaxTokens);
    });

    test('parse rejects an override window below the compaction reserve', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('zai', 'glm-5.3-flash', _yaml('''
contextWindow: 100
''')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('16384'),
          ),
        ),
      );
    });

    test('parse rejects an override maxTokens below the answer floor', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('zai', 'glm-5.3-flash', _yaml('''
maxTokens: 512
''')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('1024'),
          ),
        ),
      );
    });
  });

  group('maxTokensField selection', () {
    test('openai-completions family documents max_completion_tokens', () {
      expect(_resolve().maxTokensField, 'max_completion_tokens');
    });

    test('anthropic documents max_tokens', () {
      final caps = resolveModelCapabilities(
        provider: 'anthropic',
        modelId: 'claude-sonnet-4-5',
        spec: const ProviderSpec(
          name: 'anthropic',
          kind: 'anthropic',
          api: 'anthropic-messages',
          defaultBaseUrl: 'https://api.anthropic.com',
          apiKeyEnvNames: ['ANTHROPIC_API_KEY'],
          contextWindow: 200000,
          maxTokens: 16384,
        ),
        api: 'anthropic-messages',
      );
      expect(caps.maxTokensField, 'max_tokens');
    });

    test('google documents maxOutputTokens', () {
      final caps = resolveModelCapabilities(
        provider: 'google',
        modelId: 'gemini-2.5-pro',
        spec: const ProviderSpec(
          name: 'google',
          kind: 'google',
          api: 'google-generative-ai',
          defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKeyEnvNames: ['GOOGLE_API_KEY'],
          contextWindow: 1000000,
          maxTokens: 16384,
        ),
        api: 'google-generative-ai',
      );
      expect(caps.maxTokensField, 'maxOutputTokens');
    });

    test('spec-only callers resolve the ceiling table AND the field through '
        'the SAME effective api (gh-1426 rework)', () {
      // A caller that passes spec but no api must not document max_tokens
      // while resolving WITHOUT the Claude ceiling table — both consumers
      // read api ?? spec?.api.
      final caps = resolveModelCapabilities(
        provider: 'anthropic',
        modelId: 'claude-sonnet-4-5',
        spec: const ProviderSpec(
          name: 'anthropic',
          kind: 'anthropic',
          api: 'anthropic-messages',
          defaultBaseUrl: 'https://api.anthropic.com',
          apiKeyEnvNames: ['ANTHROPIC_API_KEY'],
          contextWindow: 200000,
          maxTokens: 16384,
        ),
      );
      expect(caps.maxTokens, 64000); // the ceiling table applied
      expect(caps.maxTokensField, 'max_tokens'); // the same effective api
    });
  });
}
