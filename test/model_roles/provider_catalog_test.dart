import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Guard: the env preconfig pick — the out-of-the-box provider activation
/// driven by API keys already in the environment — and the catalog default
/// model ids it depends on. The pick must respect catalog order, skip
/// providers without a universal default model (an env key alone must not
/// activate an endpoint with an invalid model), and ignore empty values.
void main() {
  ProviderSpec? pick(Map<String, String> env) =>
      envPreconfiguredProvider((name) => env[name]);

  group('catalogDefaultModelId', () {
    test('zai defaults to the coding endpoint flagship', () {
      expect(catalogDefaultModelId('zai'), 'glm-5.3');
    });

    test('dial has no universal default', () {
      expect(catalogDefaultModelId('dial'), isNull);
    });
  });

  group('envPreconfiguredProvider', () {
    test('ZAI_API_KEY alone activates zai', () {
      final spec = pick({'ZAI_API_KEY': 'key'});
      expect(spec?.name, 'zai');
      expect(spec?.kind, 'zai');
      expect(spec?.defaultBaseUrl, 'https://api.z.ai/api/coding/paas/v4');
    });

    test('catalog order wins when several keys are set', () {
      expect(
        pick({'ANTHROPIC_API_KEY': 'a', 'ZAI_API_KEY': 'z'})?.name,
        'anthropic',
      );
      // OPENAI_API_KEY is openrouter's fallback name: openrouter precedes
      // the openai spec in the catalog.
      expect(pick({'OPENAI_API_KEY': 'o'})?.name, 'openrouter');
    });

    test('DIAL_API_KEY alone activates nothing (no default model id)', () {
      expect(pick({'DIAL_API_KEY': 'd'}), isNull);
    });

    test('an empty env value is ignored', () {
      expect(pick({'ZAI_API_KEY': ''}), isNull);
    });

    test('no keys means no pick', () {
      expect(pick(const {}), isNull);
    });
  });
}
