import 'dart:convert';

import 'package:fa_llm/src/copilot/copilot_provider.dart';
import 'package:fa_llm/src/copilot/copilot_token_store.dart';
import 'package:fa_llm/src/llm_config.dart';
import 'package:fa_llm/src/openai_provider.dart';
import 'package:fa_llm/src/openrouter_provider.dart';
import 'package:fa_llm/src/provider_factory.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  const baseConfig = LlmConfig(
    providerName: 'openai',
    apiKey: 'key',
    baseUrl: '',
    model: 'gpt-4',
  );

  test('creates OpenAiProvider for openai provider', () {
    final provider = ProviderFactory.create(baseConfig) as OpenAiProvider;
    expect(provider.baseUrl, 'https://api.openai.com/v1/chat/completions');
  });

  test('creates OpenRouterProvider for openrouter provider', () {
    final provider =
        ProviderFactory.create(baseConfig.copyWith(providerName: 'openrouter'))
            as OpenRouterProvider;
    expect(provider.baseUrl, 'https://openrouter.ai/api/v1/chat/completions');
  });

  test('creates OpenAiProvider with ollama base url for ollama provider', () {
    final provider =
        ProviderFactory.create(baseConfig.copyWith(providerName: 'ollama'))
            as OpenAiProvider;
    expect(provider.baseUrl, 'http://localhost:11434/v1/chat/completions');
  });

  test('honors explicit base url', () {
    final provider =
        ProviderFactory.create(
              baseConfig.copyWith(
                baseUrl: 'https://custom.example.com/v1/chat/completions',
              ),
            )
            as OpenAiProvider;
    expect(provider.baseUrl, 'https://custom.example.com/v1/chat/completions');
  });

  group('copilot branch', () {
    test('defaults to the individual base URL', () {
      final provider =
          ProviderFactory.create(baseConfig.copyWith(providerName: 'copilot'))
              as CopilotProvider;
      expect(provider.baseUrl, 'https://api.githubcopilot.com');
    });

    test('accountType selects business and enterprise URLs', () {
      final business =
          ProviderFactory.create(
                baseConfig.copyWith(
                  providerName: 'copilot',
                  accountType: 'business',
                ),
              )
              as CopilotProvider;
      final enterprise =
          ProviderFactory.create(
                baseConfig.copyWith(
                  providerName: 'copilot',
                  accountType: 'enterprise',
                ),
              )
              as CopilotProvider;
      expect(business.baseUrl, 'https://api.business.githubcopilot.com');
      expect(enterprise.baseUrl, 'https://api.enterprise.githubcopilot.com');
    });

    test('explicit baseUrl override wins', () {
      final provider =
          ProviderFactory.create(
                baseConfig.copyWith(
                  providerName: 'copilot',
                  baseUrl: 'https://copilot.corp.example.com',
                ),
              )
              as CopilotProvider;
      expect(provider.baseUrl, 'https://copilot.corp.example.com');
    });

    test('unknown accountType is rejected', () {
      expect(
        () => ProviderFactory.create(
          baseConfig.copyWith(providerName: 'copilot', accountType: 'family'),
        ),
        throwsArgumentError,
      );
    });

    test('wires the token manager with store-backed GitHub token', () async {
      final store = MemoryCopilotTokenStore();
      await store.write('copilot-alice', 'gho_stored');
      final requests = <Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/copilot_internal/v2/token')) {
          return Response(
            jsonEncode({'token': 'tid', 'expires_at': 9999999999}),
            200,
          );
        }
        return Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });

      final provider =
          ProviderFactory.create(
                baseConfig.copyWith(
                  providerName: 'copilot',
                  apiKey: 'gho_config',
                  model: 'gpt-4o',
                ),
                tokenStore: store,
                entryName: 'copilot-alice',
                client: client,
              )
              as CopilotProvider;

      expect(await provider.chat('hi'), 'ok');
      final exchange = requests.firstWhere(
        (r) => r.url.path.endsWith('/v2/token'),
      );
      expect(exchange.headers['authorization'], 'token gho_stored');
      expect(requests.last.headers['authorization'], 'Bearer tid');
      expect(requests.last.url.host, 'api.githubcopilot.com');
    });

    test('falls back to config.apiKey when the store is empty', () async {
      final store = MemoryCopilotTokenStore();
      final headers = <String>[];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/copilot_internal/v2/token')) {
          headers.add(request.headers['authorization']!);
          return Response(
            jsonEncode({'token': 'tid', 'expires_at': 9999999999}),
            200,
          );
        }
        return Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          }),
          200,
        );
      });

      final provider =
          ProviderFactory.create(
                baseConfig.copyWith(
                  providerName: 'copilot',
                  apiKey: 'gho_config',
                  model: 'gpt-4o',
                ),
                tokenStore: store,
                client: client,
              )
              as CopilotProvider;

      expect(await provider.chat('hi'), 'ok');
      expect(headers, ['token gho_config']);
    });
  });
}
