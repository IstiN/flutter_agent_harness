// gh-1742 — the shared per-model context-window registry (invariant 2:
// ONE window per model identity, everywhere — main, children, smol
// summarizer and the ctx meter resolve the SAME window for the same
// `(provider, modelId, baseUrl)`).
//
// UT-3 (pure half): key normalization, publish/resolve, the AC6
// verified/unverified distinction (endpoint report or user pin), and E2
// identity isolation (a detection for one model never crosses to another).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Model _model({
  String provider = 'copilot',
  String id = 'claude-sonnet-5-5',
  String baseUrl = 'https://api.githubcopilot.com/',
  int contextWindow = 131072,
}) => Model(
  id: id,
  api: 'openai-completions',
  provider: provider,
  baseUrl: baseUrl,
  contextWindow: contextWindow,
  maxTokens: 8192,
);

void main() {
  group('ModelWindowKey (E2 identity)', () {
    test('normalizes provider case and trailing-slash base URLs', () {
      final a = ModelWindowKey.of(
        _model(baseUrl: 'https://api.example.com/v1'),
      );
      final b = ModelWindowKey.of(
        _model(baseUrl: 'https://api.example.com/v1/'),
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different model ids never share a key', () {
      expect(
        ModelWindowKey.of(_model(id: 'a')),
        isNot(ModelWindowKey.of(_model(id: 'b'))),
      );
    });

    test('different providers never share a key', () {
      expect(
        ModelWindowKey.of(_model(provider: 'openai')),
        isNot(ModelWindowKey.of(_model(provider: 'copilot'))),
      );
    });
  });

  group('ContextWindowRegistry', () {
    test('empty registry resolves nothing and verifies nothing', () {
      final registry = ContextWindowRegistry();
      final model = _model();
      expect(registry.windowFor(model), isNull);
      // AC6: no endpoint report and no user pin → the carried window is
      // UNVERIFIED.
      expect(registry.isVerified(model), isFalse);
    });

    test('publish resolves the window for the same identity', () {
      final registry = ContextWindowRegistry();
      final model = _model();
      registry.publish(
        model: model,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      expect(registry.windowFor(model), 478000);
      expect(registry.isVerified(model), isTrue);
    });

    test('resolve keys by identity, not by instance (E2)', () {
      final registry = ContextWindowRegistry();
      registry.publish(
        model: _model(),
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      // A freshly built equal-identity model (the child wiring rebuilds
      // Model instances freely) resolves the same entry.
      expect(registry.windowFor(_model()), 478000);
      // A different model on the same endpoint does not inherit it.
      expect(registry.windowFor(_model(id: 'gpt-other')), isNull);
      // A same model id on a different endpoint does not either.
      expect(
        registry.windowFor(_model(baseUrl: 'https://other.example.com/v1')),
        isNull,
      );
    });

    test('last publish wins (endpoint detection, then a user pin)', () {
      final registry = ContextWindowRegistry();
      final model = _model();
      registry.publish(
        model: model,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      registry.publish(
        model: model,
        window: 1000000,
        source: ContextWindowSource.userPin,
      );
      expect(registry.windowFor(model), 1000000);
    });

    test('non-positive windows are never registered', () {
      final registry = ContextWindowRegistry();
      final model = _model();
      registry.publish(
        model: model,
        window: 0,
        source: ContextWindowSource.endpointReport,
      );
      expect(registry.windowFor(model), isNull);
      expect(registry.isVerified(model), isFalse);
    });
  });

  group('withRegisteredContextWindow (the child-wiring shape)', () {
    test('no entry and an already-matching entry return the SAME instance', () {
      final registry = ContextWindowRegistry();
      final model = _model();
      expect(
        identical(withRegisteredContextWindow(model, registry), model),
        isTrue,
      );
      expect(
        identical(withRegisteredContextWindow(model, null), model),
        isTrue,
      );
      registry.publish(
        model: model,
        window: model.contextWindow,
        source: ContextWindowSource.endpointReport,
      );
      expect(
        identical(withRegisteredContextWindow(model, registry), model),
        isTrue,
      );
    });

    test('the wrap swaps the window and preserves EVERY other field '
        '(gh-1742 review round 1, comment 5: one shared copyWith)', () {
      final registry = ContextWindowRegistry();
      const rich = Model(
        id: 'rich-model',
        name: 'Rich',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        reasoning: true,
        input: ['text', 'image'],
        thinkingLevel: 'max',
        cost: ModelCost(input: 3, output: 4),
        contextWindow: 4000,
        maxTokens: 512,
        headers: {'x-h': '1'},
        authHeader: 'x-auth',
        capabilityNotes: ['note-1'],
        connectTimeout: Duration(seconds: 3),
        streamIdleTimeout: Duration(seconds: 60),
        timeoutScopeLabel: 'role smol override',
      );
      registry.publish(
        model: rich,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      final wrapped = withRegisteredContextWindow(rich, registry);
      expect(wrapped.contextWindow, 478000);
      expect(wrapped.id, 'rich-model');
      expect(wrapped.name, 'Rich');
      expect(wrapped.api, 'test-api');
      expect(wrapped.provider, 'test-provider');
      expect(wrapped.baseUrl, 'https://example.test');
      expect(wrapped.reasoning, isTrue);
      expect(wrapped.input, ['text', 'image']);
      expect(wrapped.thinkingLevel, 'max');
      expect(wrapped.cost.input, 3);
      expect(wrapped.cost.output, 4);
      expect(wrapped.maxTokens, 512);
      expect(wrapped.headers, {'x-h': '1'});
      expect(wrapped.authHeader, 'x-auth');
      expect(wrapped.capabilityNotes, ['note-1']);
      expect(wrapped.connectTimeout, const Duration(seconds: 3));
      expect(wrapped.streamIdleTimeout, const Duration(seconds: 60));
      expect(wrapped.timeoutScopeLabel, 'role smol override');
    });

    test('Model.copyWith: null keeps, a value swaps (the single field '
        'list lives next to the class)', () {
      const model = Model(
        id: 'm',
        api: 'test-api',
        provider: 'p',
        baseUrl: 'https://example.test',
        contextWindow: 100,
        maxTokens: 50,
        capabilityNotes: ['n'],
      );
      final swapped = model.copyWith(contextWindow: 200, maxTokens: 80);
      expect(swapped.contextWindow, 200);
      expect(swapped.maxTokens, 80);
      expect(swapped.id, 'm');
      expect(swapped.capabilityNotes, ['n']);
      expect(identical(model.copyWith(), model), isFalse);
      // An explicit null argument keeps the field (null = keep): there is
      // no way to null a non-nullable field, and the nullable ones the
      // swaps care about are never cleared.
      expect(model.copyWith(thinkingLevel: 'low').thinkingLevel, 'low');
      expect(model.thinkingLevel, isNull);
    });
  });

  group('remove (issue #1515 unpin path)', () {
    test('drops one identity and leaves the rest untouched', () {
      final registry = ContextWindowRegistry();
      final a = _model(id: 'model-a');
      final b = _model(id: 'model-b');
      registry.publish(
        model: a,
        window: 100,
        source: ContextWindowSource.userPin,
      );
      registry.publish(
        model: b,
        window: 200,
        source: ContextWindowSource.endpointReport,
      );

      registry.remove(a);
      expect(registry.windowFor(a), isNull);
      expect(registry.isVerified(a), isFalse);
      // E2 isolation: the sibling identity keeps its registration.
      expect(registry.windowFor(b), 200);
      expect(registry.isVerified(b), isTrue);
    });

    test('removing an unknown identity is a no-op', () {
      final registry = ContextWindowRegistry();
      registry.remove(_model(id: 'never-published'));
      expect(registry.entries, isEmpty);
    });
  });
}
