// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the GitHub Copilot provider adapter: the token exchange,
// the mandatory Copilot headers, the token manager, and the
// openai-completions wrapper (`streamCopilot`).
//
// Protocol facts per goal/copilot_provider.md (migrated from
// copilot-proxy-go). No real network: `http.testing` mocks only.
//
// Stream tests pass DISTINCT `githubToken`s so each gets its own
// [CopilotTokenManager] from the per-token registry (no cross-test cache).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

final _baseNow = DateTime.utc(2026, 1, 1);

String exchangeJson({required String token, required int expiresAt}) =>
    jsonEncode({'token': token, 'expires_at': expiresAt, 'refresh_in': 1500});

final copilotModel = Model(
  id: 'gpt-4.1',
  api: 'openai-completions',
  provider: 'copilot',
  baseUrl: 'https://api.githubcopilot.com',
  input: const ['text', 'image'],
  contextWindow: 1000000,
  maxTokens: 32768,
);

Model textOnlyModel() => Model(
  id: 'gpt-4.1',
  api: 'openai-completions',
  provider: 'copilot',
  baseUrl: 'https://api.githubcopilot.com',
  input: const ['text'],
  contextWindow: 1000000,
  maxTokens: 32768,
);

Context simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

Context imageContext() => Context(
  messages: [
    UserMessage(
      content: const [
        TextContent(text: 'what is this'),
        ImageContent(data: 'aGk=', mimeType: 'image/png'),
      ],
      timestamp: DateTime.utc(2026),
    ),
  ],
);

String sseChunk(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

const _doneChunk = 'data: [DONE]\n\n';

String chatSse({String text = 'Hel lo'}) =>
    sseChunk({
      'id': 'chatcmpl-1',
      'choices': [
        {
          'delta': {'content': text.substring(0, 3)},
        },
      ],
    }) +
    sseChunk({
      'id': 'chatcmpl-1',
      'choices': [
        {
          'delta': {'content': text.substring(3)},
        },
      ],
    }) +
    sseChunk({
      'id': 'chatcmpl-1',
      'choices': [
        {'delta': {}, 'finish_reason': 'stop'},
      ],
    }) +
    _doneChunk;

/// Case-insensitive header lookup (the mock keeps the keys we set; only
/// real transports normalize case).
String? hdr(http.BaseRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name) return entry.value;
  }
  return null;
}

http.StreamedResponse sseResponse(String body, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'text/event-stream'},
    );

http.StreamedResponse emptyResponse(int status) =>
    http.StreamedResponse(Stream.value(utf8.encode('')), status);

/// A mock Copilot backend: routes the token-exchange GET (api.github.com)
/// and the chat-completions POST (api.githubcopilot.com), counting calls
/// and recording requests for header assertions.
final class FakeCopilotBackend {
  FakeCopilotBackend({
    this.expiresAt,
    this.chatHandler,
    this.exchangeStatus = 200,
  });

  /// Unix seconds for the exchanged token; defaults to now + 30 min.
  int? expiresAt;

  /// Non-200 exchange status (e.g. 401 = dead GitHub token).
  int exchangeStatus;

  /// Custom token strings per exchange call (default `cop-<n>`) — the
  /// proxy-ep derivation tests embed the tenant host here.
  String Function(int exchangeCalls)? tokenFactory;

  /// Returns the response for a chat-completions POST.
  Future<http.StreamedResponse> Function(http.BaseRequest request)? chatHandler;

  var exchangeCalls = 0;
  var chatCalls = 0;
  final chatRequests = <http.BaseRequest>[];

  http.Client client() => http_testing.MockClient.streaming((
    request,
    requestBody,
  ) async {
    if (request.url.host == 'api.github.com') {
      exchangeCalls++;
      if (exchangeStatus != 200) {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"message": "bad credentials"}')),
          exchangeStatus,
        );
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            exchangeJson(
              token: tokenFactory?.call(exchangeCalls) ?? 'cop-$exchangeCalls',
              expiresAt:
                  expiresAt ?? _baseNow.millisecondsSinceEpoch ~/ 1000 + 1800,
            ),
          ),
        ),
        200,
      );
    }
    chatCalls++;
    chatRequests.add(request);
    return chatHandler!(request);
  });
}

AssistantMessage _assistantTurn() => AssistantMessage(
  content: const [TextContent(text: 'previous answer')],
  api: 'openai-completions',
  provider: 'copilot',
  model: 'gpt-4.1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

CopilotTokenManager _manager(
  FakeCopilotBackend backend, {
  DateTime Function()? now,
}) => CopilotTokenManager(
  githubToken: 'gh-1',
  client: backend.client(),
  now: now,
);

void main() {
  group('fetchCopilotApiToken', () {
    test(
      'exchanges the GitHub token with the editor identity headers',
      () async {
        http.BaseRequest? captured;
        final client = http_testing.MockClient((request) async {
          captured = request;
          return http.Response(
            exchangeJson(token: 'cop-1', expiresAt: 1900000000),
            200,
          );
        });

        final token = await fetchCopilotApiToken(
          githubToken: 'gh-1',
          client: client,
        );

        final request = captured!;
        expect(request.method, 'GET');
        expect(
          request.url,
          Uri.parse('https://api.github.com/copilot_internal/v2/token'),
        );
        expect(hdr(request, 'authorization'), 'Bearer gh-1');
        expect(hdr(request, 'accept'), 'application/json');
        expect(hdr(request, 'editor-version'), 'vscode/1.109.3');
        expect(hdr(request, 'editor-plugin-version'), 'copilot-chat/0.37.6');
        expect(hdr(request, 'user-agent'), 'GitHubCopilotChat/0.37.6');
        expect(hdr(request, 'copilot-integration-id'), 'vscode-chat');

        expect(token.token, 'cop-1');
        expect(
          token.expiresAt,
          DateTime.fromMillisecondsSinceEpoch(1900000000 * 1000, isUtc: true),
        );
        expect(token.refreshIn, 1500);
      },
    );

    test('a 401 names the dead GitHub token and the re-auth flow', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('{"message": "Bad credentials"}', 401),
      );

      await expectLater(
        fetchCopilotApiToken(githubToken: 'dead', client: client),
        throwsA(
          isA<CopilotAuthException>()
              .having(
                (e) => e.message,
                'message',
                contains('/provider copilot'),
              )
              .having((e) => e.message, 'message', contains('401')),
        ),
      );
    });

    test('other failures carry the response body', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('rate limited', 429),
      );

      await expectLater(
        fetchCopilotApiToken(githubToken: 'gh', client: client),
        throwsA(
          isA<CopilotAuthException>().having(
            (e) => e.message,
            'message',
            contains('rate limited'),
          ),
        ),
      );
    });
  });

  group('fetchGitHubLogin', () {
    test('GETs the authenticated user and returns the login', () async {
      http.BaseRequest? captured;
      final client = http_testing.MockClient((request) async {
        captured = request;
        return http.Response('{"login": "octocat"}', 200);
      });

      final login = await fetchGitHubLogin(githubToken: 'gh-1', client: client);

      expect(login, 'octocat');
      expect(captured!.url, Uri.parse('https://api.github.com/user'));
      expect(hdr(captured!, 'authorization'), 'token gh-1');
      expect(hdr(captured!, 'accept'), 'application/json');
    });

    test('a non-200 carries the status and body', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('{"message": "Bad credentials"}', 401),
      );

      await expectLater(
        fetchGitHubLogin(githubToken: 'dead', client: client),
        throwsA(
          isA<CopilotAuthException>().having(
            (e) => e.message,
            'message',
            contains('401'),
          ),
        ),
      );
    });

    test('an unexpected shape names the response', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('{}', 200),
      );

      await expectLater(
        fetchGitHubLogin(githubToken: 'gh', client: client),
        throwsA(isA<CopilotAuthException>()),
      );
    });
  });

  group('copilotApiHeaders', () {
    test('carries the mandatory Copilot headers', () {
      final headers = copilotApiHeaders(copilotToken: 'cop-1');

      expect(headers['authorization'], 'Bearer cop-1');
      expect(headers['content-type'], 'application/json');
      expect(headers['copilot-integration-id'], 'vscode-chat');
      expect(headers['editor-version'], 'vscode/1.109.3');
      expect(headers['editor-plugin-version'], 'copilot-chat/0.37.6');
      expect(headers['user-agent'], 'GitHubCopilotChat/0.37.6');
      expect(headers['openai-intent'], 'conversation-agent');
      expect(headers['x-github-api-version'], '2025-10-01');
      expect(headers['x-request-id'], isNotEmpty);
      expect(headers['x-vscode-user-agent-library-version'], 'electron-fetch');
    });

    test('mints a fresh request id per call', () {
      final first = copilotApiHeaders(copilotToken: 'cop-1');
      final second = copilotApiHeaders(copilotToken: 'cop-1');
      expect(first['x-request-id'], isNot(second['x-request-id']));
    });
  });

  group('copilotInitiatorFor', () {
    test('agent when the last message is assistant or toolResult', () {
      expect(
        copilotInitiatorFor([
          UserMessage.text('hi', timestamp: DateTime.utc(2026)),
          _assistantTurn(),
        ]),
        'agent',
      );
      expect(
        copilotInitiatorFor([
          _assistantTurn(),
          ToolResultMessage(
            toolCallId: 't1',
            toolName: 'bash',
            content: const [TextContent(text: 'ok')],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
        ]),
        'agent',
      );
    });

    test('user when the last message is user or there are none', () {
      expect(
        copilotInitiatorFor([
          _assistantTurn(),
          UserMessage.text('next', timestamp: DateTime.utc(2026)),
        ]),
        'user',
      );
      expect(copilotInitiatorFor(const []), 'user');
    });
  });

  group('CopilotTokenManager', () {
    test('caches the token until the refresh lead', () async {
      var now = _baseNow;
      final backend = FakeCopilotBackend()
        ..chatHandler = (_) async => sseResponse('');
      final manager = _manager(backend, now: () => now);

      expect(await manager.get(), 'cop-1');
      now = now.add(const Duration(minutes: 25));
      expect(await manager.get(), 'cop-1');
      expect(backend.exchangeCalls, 1); // valid beyond the 2 min lead
    });

    test('refreshes two minutes before expiry', () async {
      var now = _baseNow;
      final backend = FakeCopilotBackend()
        ..chatHandler = (_) async => sseResponse('');
      final manager = _manager(backend, now: () => now);

      await manager.get();
      now = now.add(const Duration(minutes: 28, seconds: 30));
      expect(await manager.get(), 'cop-2');
      expect(backend.exchangeCalls, 2);
    });

    test('exchanges at most once per min spacing', () async {
      var now = _baseNow;
      final backend = FakeCopilotBackend(
        // A token that dies quickly — the only case where the spacing rule
        // bites (a fresh 30 min token stays usable well past the spacing).
        expiresAt: _baseNow.millisecondsSinceEpoch ~/ 1000 + 10,
      )..chatHandler = (_) async => sseResponse('');
      final manager = _manager(backend, now: () => now);

      await manager.get();
      now = now.add(const Duration(seconds: 10));
      expect(await manager.get(), 'cop-1'); // spacing keeps the cached token
      expect(backend.exchangeCalls, 1);
      now = now.add(const Duration(seconds: 25)); // 35s since the exchange
      expect(await manager.get(), 'cop-2');
      expect(backend.exchangeCalls, 2);
    });

    test('single-flights concurrent gets into one exchange', () async {
      var exchangeCalls = 0;
      final exchangeGate = Completer<void>();
      final client = http_testing.MockClient((request) async {
        exchangeCalls++;
        await exchangeGate.future;
        return http.Response(
          exchangeJson(token: 'cop-1', expiresAt: 1900000000),
          200,
        );
      });
      final manager = CopilotTokenManager(githubToken: 'gh-1', client: client);

      final tokensFuture = Future.wait(<Future<String>>[
        manager.get(),
        manager.get(),
        manager.get(),
      ]);
      exchangeGate.complete();
      final tokens = await tokensFuture;

      expect(exchangeCalls, 1);
      expect(tokens, everyElement('cop-1'));
    });

    test('invalidate forces an immediate re-exchange', () async {
      final backend = FakeCopilotBackend()
        ..chatHandler = (_) async => sseResponse('');
      final manager = _manager(backend);

      await manager.get();
      manager.invalidate();
      expect(await manager.get(), 'cop-2');
      expect(backend.exchangeCalls, 2);
    });
  });

  group('streamCopilot', () {
    test('streams chat completions over the exchanged copilot token', () async {
      final backend = FakeCopilotBackend()
        ..chatHandler = (_) async => sseResponse(chatSse());

      final events = await streamCopilot(
        copilotModel,
        simpleContext(),
        CopilotOptions(githubToken: 'gh-happy'),
        backend.client(),
      ).toList();

      expect(backend.exchangeCalls, 1);
      expect(backend.chatCalls, 1);
      final request = backend.chatRequests.single;
      expect(
        request.url,
        Uri.parse('https://api.githubcopilot.com/chat/completions'),
      );
      expect(hdr(request, 'authorization'), 'Bearer cop-1');
      expect(hdr(request, 'copilot-integration-id'), 'vscode-chat');
      expect(hdr(request, 'openai-intent'), 'conversation-agent');
      expect(hdr(request, 'x-github-api-version'), '2025-10-01');
      expect(hdr(request, 'x-request-id'), isNotEmpty);
      expect(hdr(request, 'x-initiator'), 'user'); // last message is user
      expect(hdr(request, 'copilot-vision-request'), isNull); // no images

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas.map((d) => d.delta).join(), 'Hel lo');
      final done = events.last as DoneEvent;
      expect(done.reason, StopReason.stop);
    });

    test(
      'sends X-Initiator: agent when the last message is the assistant',
      () async {
        final backend = FakeCopilotBackend()
          ..chatHandler = (_) async => sseResponse(chatSse());

        await streamCopilot(
          copilotModel,
          Context(
            messages: [
              UserMessage.text('hi', timestamp: DateTime.utc(2026)),
              _assistantTurn(),
            ],
          ),
          CopilotOptions(githubToken: 'gh-agent'),
          backend.client(),
        ).toList();

        expect(hdr(backend.chatRequests.single, 'x-initiator'), 'agent');
      },
    );

    test(
      'sends Copilot-Vision-Request: true only when images ride along',
      () async {
        Future<String?> visionHeader(Model model, Context context) async {
          final backend = FakeCopilotBackend()
            ..chatHandler = (_) async => sseResponse(chatSse());
          await streamCopilot(
            model,
            context,
            CopilotOptions(githubToken: 'gh-vision'),
            backend.client(),
          ).toList();
          return hdr(backend.chatRequests.single, 'copilot-vision-request');
        }

        expect(await visionHeader(copilotModel, imageContext()), 'true');
        expect(await visionHeader(copilotModel, simpleContext()), isNull);
        // Images in the transcript but a text-only model: the adapter
        // downgrades them, so the request carries none.
        expect(await visionHeader(textOnlyModel(), imageContext()), isNull);
      },
    );

    test(
      'a 401 refreshes the copilot token and retries exactly once',
      () async {
        final backend = FakeCopilotBackend();
        backend.chatHandler = (_) async => backend.chatCalls == 1
            ? emptyResponse(401)
            : sseResponse(chatSse(text: 'recovered'));

        final events = await streamCopilot(
          copilotModel,
          simpleContext(),
          CopilotOptions(
            githubToken: 'gh-401',
            tokenManager: _manager(backend),
          ),
          backend.client(),
        ).toList();

        expect(backend.exchangeCalls, 2); // initial + refresh after 401
        expect(backend.chatCalls, 2);
        expect(hdr(backend.chatRequests.last, 'authorization'), 'Bearer cop-2');
        expect(
          events.whereType<TextDeltaEvent>().map((d) => d.delta).join(),
          'recovered',
        );
        expect(events.last, isA<DoneEvent>());
      },
    );

    test('a second consecutive 401 is surfaced, not retried again', () async {
      final backend = FakeCopilotBackend();
      backend.chatHandler = (_) async => emptyResponse(401);

      final events = await streamCopilot(
        copilotModel,
        simpleContext(),
        CopilotOptions(githubToken: 'gh-401-twice'),
        backend.client(),
      ).toList();

      expect(backend.chatCalls, 2); // initial + exactly one retry
      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
    });

    test('a non-auth error surfaces without a retry', () async {
      final backend = FakeCopilotBackend();
      backend.chatHandler = (_) async => http.StreamedResponse(
        Stream.value(utf8.encode('server exploded')),
        500,
      );

      final events = await streamCopilot(
        copilotModel,
        simpleContext(),
        CopilotOptions(githubToken: 'gh-500'),
        backend.client(),
      ).toList();

      expect(backend.chatCalls, 1);
      expect(backend.exchangeCalls, 1);
      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });

    test('a dead GitHub token becomes an error event naming re-auth', () async {
      final backend = FakeCopilotBackend()..exchangeStatus = 401;

      final events = await streamCopilot(
        copilotModel,
        simpleContext(),
        CopilotOptions(githubToken: 'gh-dead'),
        backend.client(),
      ).toList();

      expect(backend.chatCalls, 0);
      final error = events.whereType<ErrorEvent>().single;
      expect(error.reason, StopReason.error);
      expect(error.error.errorMessage, contains('/provider copilot'));
    });
  });

  group('copilot /models dialect', () {
    http.Client modelsClient(
      FakeCopilotBackend backend,
      void Function(http.BaseRequest) onModels,
      String modelsBody,
    ) => http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        backend.exchangeCalls++;
        return http.Response(
          exchangeJson(
            token: backend.tokenFactory?.call(1) ?? 'cop-1',
            expiresAt: 1900000000,
          ),
          200,
        );
      }
      onModels(request);
      return http.Response(modelsBody, 200);
    });

    test('exchanges then GETs /models with the copilot token', () async {
      final backend = FakeCopilotBackend();
      http.BaseRequest? modelsRequest;
      final client = modelsClient(
        backend,
        (request) => modelsRequest = request,
        jsonEncode({
          'data': [
            {
              'id': 'gpt-4.1',
              'capabilities': {
                'limits': {
                  'max_context_window_tokens': 1000000,
                  'max_output_tokens': 32768,
                },
              },
              'supported_endpoints': ['/chat/completions'],
            },
            {
              'id': 'claude-sonnet-4',
              'capabilities': {
                'limits': {
                  'max_context_window_tokens': 200000,
                  'max_output_tokens': 8192,
                },
              },
            },
            {'id': 'no-limits-model'},
          ],
        }),
      );

      final (ids, windows, caps) = await fetchModelsForEndpoint(
        'https://api.githubcopilot.com',
        apiKey: 'gh-1',
        provider: 'copilot',
        client: client,
      );

      expect(backend.exchangeCalls, 1);
      expect(
        modelsRequest!.url,
        Uri.parse('https://api.githubcopilot.com/models'),
      );
      expect(hdr(modelsRequest!, 'authorization'), 'Bearer cop-1');
      expect(ids, ['claude-sonnet-4', 'gpt-4.1', 'no-limits-model']);
      expect(windows['gpt-4.1'], 1000000);
      expect(windows['claude-sonnet-4'], 200000);
      expect(caps['gpt-4.1'], 32768);
    });

    test('matches githubcopilot hosts without a provider hint', () async {
      final backend = FakeCopilotBackend();
      var sawModels = false;
      final client = modelsClient(
        backend,
        (_) => sawModels = true,
        jsonEncode({'data': []}),
      );

      final (ids, _, _) = await fetchModelsForEndpoint(
        'https://api.business.githubcopilot.com',
        apiKey: 'gh-1',
        client: client,
      );

      expect(sawModels, isTrue);
      expect(ids, isEmpty);
    });

    test('any failure answers empty info', () async {
      final client = http_testing.MockClient(
        (_) async => http.Response('{"message": "Bad credentials"}', 401),
      );

      final (ids, windows, caps) = await fetchModelsForEndpoint(
        'https://api.githubcopilot.com',
        apiKey: 'gh-1',
        provider: 'copilot',
        client: client,
      );

      expect(ids, isEmpty);
      expect(windows, isEmpty);
      expect(caps, isEmpty);
    });
  });

  group('copilot catalog entry', () {
    tearDown(() => providerFilterEnvOverride = null);

    test('the spec carries the Copilot defaults', () {
      final spec = catalogProvider('copilot');
      expect(spec, isNotNull);
      expect(spec!.kind, 'copilot');
      expect(spec.api, 'openai-completions');
      expect(spec.defaultBaseUrl, 'https://api.githubcopilot.com');
      expect(spec.apiKeyEnvNames, ['COPILOT_GITHUB_TOKEN']);
      expect(spec.contextWindow, 1000000);
      expect(spec.maxTokens, 32768);
      expect(spec.visible, isTrue);
    });

    test('the kind builds a copilot stream function', () {
      expect(() => providerStreamFunction('copilot', 'gh-1'), returnsNormally);
    });

    test('buildCliDefaultModel defaults to gpt-4.1', () {
      final model = buildCliDefaultModel('copilot');
      expect(model.id, 'gpt-4.1');
      expect(model.baseUrl, 'https://api.githubcopilot.com');
    });

    test('copilot is a legal custom-provider api type and cli kind', () {
      expect(customProviderApiTypes, contains('copilot'));
      expect(cliProviderKinds, contains('copilot'));
    });

    test('the FA_PROVIDERS filter honors copilot', () {
      providerFilterEnvOverride = 'copilot';
      expect(enabledProviderNames(), ['copilot']);
      expect(catalogProvider('copilot'), isNotNull);
      providerFilterEnvOverride = 'dial';
      expect(catalogProvider('copilot'), isNull);
    });
  });

  group('copilotApiBaseUrlFromToken', () {
    test('parses proxy-ep into the tenant API host', () {
      expect(
        copilotApiBaseUrlFromToken(
          'tid=abc;exp=1900000000;proxy-ep=proxy.tenant-x.githubcopilot.com;sku=enterprise',
        ),
        'https://api.tenant-x.githubcopilot.com',
      );
      expect(
        copilotApiBaseUrlFromToken('proxy-ep=proxy.business.githubcopilot.com'),
        'https://api.business.githubcopilot.com',
      );
    });

    test('returns null without a proxy-ep field', () {
      expect(copilotApiBaseUrlFromToken('cop-1'), isNull);
      expect(copilotApiBaseUrlFromToken(''), isNull);
    });
  });

  group('token-derived tenant host (proxy-ep)', () {
    test('the chat POST follows the token proxy-ep host', () async {
      final backend = FakeCopilotBackend(
        chatHandler: (request) async => sseResponse(chatSse() + _doneChunk),
      );
      backend.tokenFactory = (n) =>
          'tid=t;exp=1900000000;proxy-ep=proxy.tenant-x.githubcopilot.com';

      final message = await streamCopilot(
        copilotModel,
        simpleContext(),
        const CopilotOptions(githubToken: 'gh-tenant-x'),
        backend.client(),
      ).result;

      expect(message.stopReason, StopReason.stop);
      expect(backend.chatRequests, hasLength(1));
      expect(
        backend.chatRequests.single.url,
        Uri.parse(
          'https://api.tenant-x.githubcopilot.com/chat/completions',
        ),
        reason: 'the token names the tenant host, not the tier picker',
      );
    });

    test('a proxy-ep-less token keeps the configured base URL', () async {
      final backend = FakeCopilotBackend(
        chatHandler: (request) async => sseResponse(chatSse() + _doneChunk),
      );

      final message = await streamCopilot(
        copilotModel,
        simpleContext(),
        const CopilotOptions(githubToken: 'gh-plain'),
        backend.client(),
      ).result;

      expect(message.stopReason, StopReason.stop);
      expect(backend.chatRequests.single.url.host, 'api.githubcopilot.com');
    });

    test('/models follows the token proxy-ep host', () async {
      http.BaseRequest? modelsRequest;
      final client = http_testing.MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            exchangeJson(
              token: 'proxy-ep=proxy.tenant-y.githubcopilot.com;exp=1900000000',
              expiresAt: 1900000000,
            ),
            200,
          );
        }
        modelsRequest = request;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-4.1',
                'capabilities': {
                  'limits': {
                    'max_context_window_tokens': 1000000,
                    'max_output_tokens': 32768,
                  },
                },
              },
            ],
          }),
          200,
        );
      });

      final (ids, _, _) = await fetchModelsForEndpoint(
        'https://api.enterprise.githubcopilot.com',
        apiKey: 'gh-1',
        provider: 'copilot',
        client: client,
      );

      expect(ids, ['gpt-4.1']);
      expect(
        modelsRequest!.url,
        Uri.parse('https://api.tenant-y.githubcopilot.com/models'),
        reason: 'the configured enterprise tier host is only the fallback',
      );
    });
  });
}
