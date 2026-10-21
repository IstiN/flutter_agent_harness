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
        registry.windowFor(
          _model(baseUrl: 'https://other.example.com/v1'),
        ),
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
}
