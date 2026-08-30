// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The providerKind: 'copilot' dispatch-chain tests: every `kind` dispatch
// site the Copilot provider flows through in one run —
//
//   1. the role fallback chain (ModelRolesResolver → providerStreamFunction
//      → streamCopilot), including a mid-turn 429 takeover,
//   2. the `inspect_image` tool dispatch (Copilot rides streamCopilot, not
//      the plain openai-completions branch),
//   3. the /models cache refresh (the Copilot dialect token exchange), which
//      must override the catalog's contextWindow/maxTokens defaults from the
//      endpoint-reported `capabilities.limits` — and keep those defaults
//      when the payload has no opinion.
//
// No real network: `http.testing` mocks only. Distinct GitHub tokens per
// phase so each gets its own [CopilotTokenManager] from the per-token
// registry (no cross-test cache).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

String _exchangeJson(String token) => jsonEncode({
  'token': token,
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1800,
  'refresh_in': 1500,
});

String _sseChunk(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

String _chatSse(String text) =>
    '${_sseChunk({
      'id': 'chatcmpl-1',
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    })}${_sseChunk({
      'id': 'chatcmpl-1',
      'choices': [
        {'delta': {}, 'finish_reason': 'stop'},
      ],
    })}data: [DONE]\n\n';

http.StreamedResponse _sseResponse(String body, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'text/event-stream'},
    );

Uint8List _makePng() {
  final image = img.Image(width: 2, height: 2)..getPixel(0, 0).r = 255;
  return Uint8List.fromList(img.encodePng(image));
}

String? _hdr(http.BaseRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

/// A mock Copilot backend serving the three wire surfaces the dispatch chain
/// touches: the token exchange (api.github.com), `/models` (fixture
/// payload), and chat completions (scripted queue of responses).
final class _DispatchBackend {
  _DispatchBackend({this.modelsPayload, List<http.StreamedResponse>? chats})
    : chatQueue = chats ?? [];

  /// The fixture `/models` JSON body; null answers 404 (empty id list).
  String? modelsPayload;

  /// Scripted chat responses, consumed in order; the last one repeats.
  final List<http.StreamedResponse> chatQueue;

  var exchangeCalls = 0;
  var modelsCalls = 0;
  var chatCalls = 0;
  final chatRequests = <http.BaseRequest>[];

  http.Client client() => http_testing.MockClient.streaming((request, _) async {
    if (request.url.host == 'api.github.com') {
      exchangeCalls++;
      return http.StreamedResponse(
        Stream.value(utf8.encode(_exchangeJson('cop-$exchangeCalls'))),
        200,
      );
    }
    if (request.url.path.endsWith('/models')) {
      modelsCalls++;
      final payload = modelsPayload;
      if (payload == null) {
        return http.StreamedResponse(Stream.value(utf8.encode('{}')), 404);
      }
      return http.StreamedResponse(Stream.value(utf8.encode(payload)), 200);
    }
    chatCalls++;
    chatRequests.add(request);
    if (chatQueue.isEmpty) return _sseResponse(_chatSse('ok'));
    final first = chatQueue.removeAt(0);
    final second = chatQueue.isEmpty ? first : chatQueue.removeAt(0);
    return second;
  });
}

Context _simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

Model _copilotModel(String id) => Model(
  id: id,
  name: id,
  api: 'openai-completions',
  provider: 'copilot',
  baseUrl: 'https://api.githubcopilot.com',
  input: const ['text', 'image'],
  contextWindow: 1000000,
  maxTokens: 32768,
);

void main() {
  test(
    'providerKind copilot drives the whole dispatch chain: '
    'role fallback takeover, inspect_image, /models limits override',
    () async {
      // ── 1. Role fallback chain: copilot entries resolve through the
      // catalog dispatch and a mid-turn 429 on entry 1 takes over to
      // entry 2 without leaking entry 1's events. The factory delegates to
      // the real [providerStreamFunction] first (the kind allowlist under
      // test — 'copilot' must be admitted), then injects the mocked client
      // for the copilot wire (the resolver-built adapters dial the shared
      // keep-alive client, which no unit test may touch).
      final chainBackend = _DispatchBackend(
        chats: [_sseResponse('429: rate limit exceeded', 429)],
      );
      StreamFunction factory(String kind, String apiKey) {
        final real = providerStreamFunction(kind, apiKey);
        if (kind != 'copilot') return real;
        return (model, context, {cancelToken}) => streamCopilot(
          model,
          context,
          CopilotOptions(githubToken: apiKey, cancelToken: cancelToken),
          chainBackend.client(),
        );
      }

      final notices = <FallbackNotice>[];
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: {
            'default': const [
              ModelRef(provider: 'copilot', modelId: 'gpt-4.1'),
              ModelRef(provider: 'copilot', modelId: 'gpt-4.1-mini'),
            ],
          },
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {'COPILOT_GITHUB_TOKEN': 'gh-chain-dispatch-1'},
        onNotice: notices.add,
        sleeper: (delay, _) async => true,
        streamFactory: factory,
      );
      final wrapper = resolver.streamForRole('default');
      final events = await wrapper
          .call(_copilotModel('gpt-4.1'), _simpleContext())
          .toList();

      // Only entry 2's turn was forwarded — the rate-limited attempt left
      // no trace — and the takeover was announced.
      expect(
        [
          for (final event in events)
            if (event is DoneEvent) event.message.model,
        ],
        ['gpt-4.1-mini'],
      );
      expect(events.whereType<ErrorEvent>(), isEmpty);
      expect(notices, hasLength(1));
      expect(notices.single.kind, FallbackNoticeKind.modelFallback);
      expect(chainBackend.chatCalls, 2); // 429 attempt + takeover

      // ── 2. inspect_image dispatch: providerKind copilot rides the
      // token-exchange dialect (the GitHub token must NOT go out as the
      // Bearer header on the chat endpoint).
      final inspectBackend = _DispatchBackend();
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final tool = inspectImageTool(
        env,
        InspectImageConfig(
          modelId: 'gpt-4o-mini',
          apiKey: 'gh-inspect-dispatch-2',
          providerKind: 'copilot',
          httpClient: inspectBackend.client(),
        ),
      );
      final result = await tool.execute(
        {'path': '/work/shot.png', 'prompt': 'what is this?'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'ok');
      expect(inspectBackend.chatCalls, 1);
      final chat = inspectBackend.chatRequests.single;
      expect(
        _hdr(chat, 'authorization'),
        'Bearer cop-1', // the exchanged Copilot token, not the GitHub token
      );
      expect(_hdr(chat, 'copilot-integration-id'), 'vscode-chat');

      // ── 3. Model refresh: the periodic /models warm-up routes through the
      // Copilot dialect and the endpoint-reported limits replace the
      // catalog's 1000000/32768 defaults.
      final refreshBackend = _DispatchBackend(
        modelsPayload: jsonEncode({
          'data': [
            {
              'id': 'gpt-4.1',
              'capabilities': {
                'limits': {
                  'max_context_window_tokens': 128000,
                  'max_output_tokens': 8192,
                },
              },
            },
            {'id': 'gpt-5'},
          ],
        }),
      );
      final changed = <Model>[];
      final io = FakeCliIO();
      addTearDown(io.close);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _copilotModel('gpt-4.1'),
          apiKey: 'gh-refresh-dispatch-3',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'copilot',
          modelsHttpClient: refreshBackend.client(),
          onModelChanged: changed.add,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      await cli.runHeadless('hello');
      expect(refreshBackend.modelsCalls, 1); // dialect ran, not raw Bearer
      expect(changed, isNotEmpty);
      expect(changed.last.contextWindow, 128000);
      expect(changed.last.maxTokens, 8192);
    },
  );

  test(
    'models refresh fallback: no advertised limits keeps catalog defaults',
    () async {
      // The payload lists ids but carries NO limits — the catalog's
      // 1000000/32768 copilot defaults stay (pre-/models fallback only).
      final backend = _DispatchBackend(
        modelsPayload: jsonEncode({
          'data': [
            {
              'id': 'gpt-4.1',
              'capabilities': {'limits': <String, dynamic>{}},
            },
          ],
        }),
      );
      final changed = <Model>[];
      final io = FakeCliIO();
      addTearDown(io.close);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _copilotModel('gpt-4.1'),
          apiKey: 'gh-refresh-dispatch-4',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'copilot',
          modelsHttpClient: backend.client(),
          onModelChanged: changed.add,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      await cli.runHeadless('hello');
      expect(backend.modelsCalls, 1);
      for (final model in changed) {
        expect(model.contextWindow, 1000000);
        expect(model.maxTokens, 32768);
      }
    },
  );
}
