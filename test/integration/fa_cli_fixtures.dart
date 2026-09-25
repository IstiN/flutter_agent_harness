/// Shared fixtures for the fa_cli_* PTY integration suites (issue #931
/// part 3.4: fa_cli_integration_test.dart was one 849-line file — the
/// scheduler's parallelism unit is the FILE, so its ~2.5 min dominated one
/// wave of every shard. The tests are split along these fixtures instead
/// of duplicating them per file).
///
/// Not a `*_test.dart` file: `dart test` never picks this up as a suite.
library;

import 'dart:convert';
import 'dart:io';

/// One factory, four shapes: the temp-dir + `.fah/config.yaml` scaffolding
/// lives here; each named fixture below supplies only its config body
/// (public names kept so the transplanted test bodies stay byte-faithful).
Directory makeTempHomeWith(String configYaml) {
  final tempHome = Directory.systemTemp.createTempSync('fa_test_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync(configYaml);
  return tempHome;
}

/// Creates a temp HOME with a minimal keyless config (yolo mode so tests
/// never hit an approval gate).
Directory makeTempHome() => makeTempHomeWith('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
tui:
  classic: true  # pins the classic chrome the boot status-line assert needs (band redesign #805-#807 has its own surface)
''');

/// Creates a temp HOME with a saved custom provider in the registry.
Directory makeTempHomeWithProvider() => makeTempHomeWith('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
customProviders:
  - name: test-provider
    apiType: openai
    baseUrl: http://localhost:9999/v1
    modelId: test-model
''');

/// Creates a temp HOME with always-ask approval mode.
Directory makeTempHomeWithApproval() => makeTempHomeWith('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: always-ask
allowedTools: []
''');

/// Creates a temp HOME pointing the provider at the local mock server with
/// always-ask approval gating.
Directory makeTempHomeForMock(int port) => makeTempHomeWith('''
provider: openai-completions
model: test-model
baseUrl: http://127.0.0.1:$port/v1
mode: code
approvalMode: always-ask
allowedTools: []
''');

/// A tiny OpenAI-compatible SSE server: the first request answers with a
/// scripted bash tool call, every later one with a plain text answer.
final class MockOpenAiServer {
  HttpServer? _server;
  final List<String> bodies = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      // The boot-time model-cache refresh must not consume a scripted
      // chat turn.
      if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list', 'data': []}));
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          !request.uri.path.endsWith('/chat/completions')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      bodies.add(body);
      final n = bodies.length - 1;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final chunks = n == 0 ? _toolCallChunks() : _textChunks();
      for (final chunk in chunks) {
        // A blank line terminates each SSE event — without it the decoder
        // concatenates every data line into one unreadable payload.
        request.response.write('data: $chunk\n\n');
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }

  static List<String> _toolCallChunks() => [
    jsonEncode({
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'bash', 'arguments': ''},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': '{"command": "echo ECHO-RAN-123"}'},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
      ],
    }),
  ];

  static List<String> _textChunks() => [
    jsonEncode({
      'id': 'chatcmpl-2',
      'object': 'chat.completion.chunk',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': 'turn-complete'},
          'finish_reason': null,
        },
      ],
    }),
    jsonEncode({
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
      ],
    }),
  ];
}

/// An OpenAI-compatible SSE mock that streams `reasoning_content` deltas
/// SLOWLY (one every 150ms for ~15s, for every chat request) so a test has
/// a long window to interact with the run mid-thinking-stream. The abort
/// under test closes the stream before the script finishes.
final class SlowThinkingMockServer {
  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((request) async {
      if (request.method == 'GET' && request.uri.path.endsWith('/models')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'object': 'list', 'data': []}));
        await request.response.close();
        return;
      }
      if (request.method != 'POST' ||
          !request.uri.path.endsWith('/chat/completions')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      Map<String, dynamic> chunk(String reasoning) => {
        'id': 'chatcmpl-think',
        'object': 'chat.completion.chunk',
        'model': 'test-model',
        'choices': [
          {
            'index': 0,
            'delta': {'reasoning_content': reasoning},
            'finish_reason': null,
          },
        ],
      };
      for (var i = 0; i < 100; i++) {
        request.response.write('data: ${jsonEncode(chunk('t$i '))}\n\n');
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
