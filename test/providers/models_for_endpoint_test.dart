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
      'chatgpt: live /models with OAuth-blob credentials, known ids enriched',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response(
            '{"data":[{"id":"gpt-5.6-sol"},{"id":"brand-new-model"}]}',
            200,
          );
        });
        final blob = const ChatGptOAuthCredentials(
          accessToken: 'at-1',
          refreshToken: 'rt-1',
          idToken: 'it-1',
          accountId: 'acc-1',
        ).encode();
        final (ids, windows, caps) = await fetchModelsForEndpoint(
          'https://chatgpt.com/backend-api/codex',
          apiKey: blob,
          provider: 'chatgpt',
          client: client,
        );
        expect(
          seen!.url.toString(),
          'https://chatgpt.com/backend-api/codex/models',
        );
        expect(seen!.headers['authorization'], 'Bearer at-1');
        expect(seen!.headers['ChatGPT-Account-ID'], 'acc-1');
        expect(seen!.headers['originator'], 'codex_cli_rs');
        expect(seen!.headers['session-id'], isNotEmpty);
        expect(
          seen!.headers['thread-id'],
          seen!.headers['x-client-request-id'],
        );
        expect(seen!.headers['accept'], 'application/json');
        expect(ids, ['brand-new-model', 'gpt-5.6-sol']);
        expect(windows['gpt-5.6-sol'], 272000);
        expect(windows['brand-new-model'], isNull);
        expect(caps['gpt-5.6-sol'], 16384);
      },
    );

    test(
      'chatgpt by URL alone: a 401 probe answers the bundled Codex catalog',
      () async {
        final client = http_testing.MockClient(
          (request) async => http.Response('unauthorized', 401),
        );
        final (ids, windows, _) = await fetchModelsForEndpoint(
          'https://chatgpt.com/backend-api/codex',
          apiKey: 'irrelevant',
          client: client,
        );
        expect(ids, containsAll(chatGptCodexModels));
        expect(ids.first, 'gpt-5.6-sol');
        expect(windows[ids.first], 272000);
      },
    );

    test(
      'chatgpt: a malformed /models body answers the bundled catalog',
      () async {
        final client = http_testing.MockClient(
          (request) async => http.Response('<html>challenge</html>', 200),
        );
        final (ids, _, _) = await fetchModelsForEndpoint(
          'https://chatgpt.com/backend-api/codex',
          apiKey: 'irrelevant',
          provider: 'chatgpt-codex',
          client: client,
        );
        expect(ids, containsAll(chatGptCodexModels));
      },
    );

    test('chatgpt: an empty data list answers the bundled catalog', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"data":[]}', 200),
      );
      final (ids, _, _) = await fetchModelsForEndpoint(
        'https://chatgpt.com/backend-api/codex',
        apiKey: 'irrelevant',
        provider: 'chatgpt',
        client: client,
      );
      expect(ids, containsAll(chatGptCodexModels));
    });

    test(
      'chatgpt: a raw non-blob key rides as the bearer, bundled on empty',
      () async {
        http.Request? seen;
        final client = http_testing.MockClient((request) async {
          seen = request;
          return http.Response('{"data":[]}', 200);
        });
        final (ids, _, _) = await fetchModelsForEndpoint(
          'https://chatgpt.com/backend-api/codex',
          apiKey: 'raw-token',
          provider: 'chatgpt',
          client: client,
        );
        expect(seen!.headers['authorization'], 'Bearer raw-token');
        expect(seen!.headers['ChatGPT-Account-ID'], isNull);
        expect(ids, containsAll(chatGptCodexModels));
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

    test(
      'copilot: only picker-enabled, chat-completions models are listed',
      () async {
        // The dialect exchanges the GitHub token first, then filters the
        // payload pi-style (model_picker_enabled + policy.state +
        // supports.tool_calls) — plus, for payloads declaring
        // supported_endpoints, /chat/completions must be among them:
        // responses-only models (gpt-5.6-sol) 400 on our chat transport.
        final client = http_testing.MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              '{"token":"tid=x","expires_at":9999999999}',
              200,
            );
          }
          expect(request.url.path, endsWith('/models'));
          return http.Response(
            '{"data":['
            // kept: picker-enabled, no supported_endpoints field
            '{"id":"gpt-4.1","model_picker_enabled":true,'
            '"capabilities":{"supports":{"tool_calls":true},"limits":'
            '{"max_context_window_tokens":128000}}},'
            // kept: explicitly served on /chat/completions
            '{"id":"claude-sonnet-5","model_picker_enabled":true,'
            '"supported_endpoints":["/chat/completions","/responses"]},'
            // dropped: picker-disabled (embeddings/legacy)
            '{"id":"text-embedding-3-small","model_picker_enabled":false},'
            // dropped: policy-disabled
            '{"id":"old-model","model_picker_enabled":true,'
            '"policy":{"state":"disabled"}},'
            // dropped: no tool calls
            '{"id":"no-tools","model_picker_enabled":true,'
            '"capabilities":{"supports":{"tool_calls":false}}},'
            // dropped: responses-only (the gpt-5.6-sol 400)
            '{"id":"gpt-5.6-sol","model_picker_enabled":true,'
            '"policy":{"state":"enabled"},'
            '"capabilities":{"supports":{"tool_calls":true}},'
            '"supported_endpoints":["/responses","ws:/responses"]}'
            ']}',
            200,
          );
        });
        final (ids, windows, _) = await fetchModelsForEndpoint(
          'https://api.enterprise.githubcopilot.com',
          apiKey: 'gh-token',
          provider: 'copilot',
          client: client,
        );
        expect(ids, ['claude-sonnet-5', 'gpt-4.1']);
        expect(windows['gpt-4.1'], 128000);
      },
    );
  });
}
