// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('fetchModelsForEndpoint', () {
    test(
      'openai-compatible: GETs {baseUrl}/models with the Bearer key',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '{"data":[{"id":"b-model","context_length":12345},'
            '{"id":"a-model","max_completion_tokens":4096}]}',
            200,
          );
        });
        final (ids, windows, caps) = await fetchModelsForEndpoint(
          'https://api.example.com/v1/',
          apiKey: 'sk-1',
          client: client,
        );
        expect(seen!.url.toString(), 'https://api.example.com/v1/models');
        expect(seen!.headers['authorization'], 'Bearer sk-1');
        expect(ids, ['a-model', 'b-model']);
        expect(windows['b-model'], 12345);
        expect(caps['a-model'], 4096);
      },
    );

    test(
      'codemie marker: the /llm_models dialect wins over the provider hint',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '[{"id":"litellm-1"},{"base_name":"litellm-2"}]',
            200,
          );
        });
        final (ids, _, _) = await fetchModelsForEndpoint(
          'https://org.example.com/code-assistant-api/v1',
          apiKey: 'cookie-string',
          provider: 'dial', // must be ignored — the marker wins
          client: client,
        );
        expect(
          seen!.url.toString(),
          'https://org.example.com/code-assistant-api/v1/llm_models'
          '?include_all=true',
        );
        expect(ids, containsAll(['litellm-1', 'litellm-2']));
      },
    );

    test(
      'chatgpt-codex hint: returns the bundled Codex catalog without hitting /models',
      () async {
        // The Codex backend has no public /models endpoint; the picker
        // must serve the bundled list (mirrors codex-rs/models-manager/
        // models.json) so users always have something to pick from.
        final client = http_testing.MockClient((request) async {
          fail('chatgpt-codex must NOT issue an HTTP /models probe');
        });
        final (ids, windows, caps) = await fetchModelsForEndpoint(
          'https://chatgpt.com/backend-api/codex',
          apiKey: 'irrelevant',
          provider: 'chatgpt-codex',
          client: client,
        );
        expect(ids, containsAll(chatGptCodexModels));
        expect(ids.first, 'gpt-5.6-sol');
        expect(windows[ids.first], 272000);
        expect(caps[ids.first], 16384);
      },
    );

    test(
      'dial hint: deployments from /openai/models with reported limits',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '{"data":[{"id":"terra","limits":{"max_prompt_tokens":200000,'
            '"max_completion_tokens":128000}}]}',
            200,
          );
        });
        final (ids, windows, caps) = await fetchModelsForEndpoint(
          'https://dial.example.com',
          apiKey: 'dial-key',
          provider: 'dial',
          client: client,
        );
        expect(seen!.url.toString(), 'https://dial.example.com/openai/models');
        expect(seen!.headers['Api-Key'], 'dial-key');
        expect(ids, ['terra']);
        expect(windows['terra'], 200000);
        expect(caps['terra'], 128000);
      },
    );

    test(
      'google hint: list models with x-goog-api-key header, strip the "models/" prefix',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '{"models":[{"name":"models/gemini-2.0-flash"},'
            '{"name":"models/gemini-2.0-pro"}]}',
            200,
          );
        });
        final (ids, _, _) = await fetchModelsForEndpoint(
          'https://generativelanguage.googleapis.com/v1beta',
          apiKey: 'google-key',
          client: client,
        );
        expect(
          seen!.url.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models',
        );
        expect(seen!.headers['x-goog-api-key'], 'google-key');
        expect(seen!.headers['authorization'], isNull);
        expect(ids, ['gemini-2.0-flash', 'gemini-2.0-pro']);
      },
    );

    test(
      'failures answer an empty info (manual entry stays the fallback)',
      () async {
        final cases = <Future<ModelsEndpointInfo> Function()>[
          // Non-200.
          () => fetchModelsForEndpoint(
            'https://x.example.com',
            apiKey: '',
            client: http_testing.MockClient(
              (request) async => http.Response('nope', 500),
            ),
          ),
          // Invalid JSON.
          () => fetchModelsForEndpoint(
            'https://x.example.com',
            apiKey: '',
            client: http_testing.MockClient(
              (request) async => http.Response('<html>404</html>', 200),
            ),
          ),
          // Transport error.
          () => fetchModelsForEndpoint(
            'https://x.example.com',
            apiKey: '',
            client: http_testing.MockClient(
              (request) async => throw Exception('connection refused'),
            ),
          ),
          // Codemie auth failure.
          () => fetchModelsForEndpoint(
            'https://org.example.com/code-assistant-api/v1',
            apiKey: 'bad',
            client: http_testing.MockClient(
              (request) async => http.Response('unauthorized', 401),
            ),
          ),
        ];
        for (final run in cases) {
          final (ids, windows, caps) = await run();
          expect(ids, isEmpty);
          expect(windows, isEmpty);
          expect(caps, isEmpty);
        }
      },
    );
  });
}
