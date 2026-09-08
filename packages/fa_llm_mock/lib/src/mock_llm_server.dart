/// Scripted OpenAI-compatible mock LLM server for integration tests.
///
/// Binds a loopback HTTP server on an ephemeral port and answers
/// `POST <baseUrl>/chat/completions` (the exact path
/// `streamOpenAICompletions` builds: `{model.baseUrl}/chat/completions`)
/// with OpenAI-style SSE chunks carrying the scripted responses:
///
/// - [MockToolCall]: one streamed `tool_calls` delta plus
///   `finish_reason: "tool_calls"`.
/// - [MockText]: one `content` delta plus `finish_reason: "stop"`.
/// - [MockToolResultEcho]: a `content` response echoing back the text of
///   the last `role: "tool"` message in the request (what a real model
///   would quote); proves the tool result actually flowed through the
///   sandbox.
/// - [MockError]: HTTP error simulation — the requested status with a
///   JSON error body, surfaced by adapters as an error turn.
///
/// The script comes either from a config document
/// (`MockLlmScript.parse`) with per-user-message scenarios and response
/// queues, or programmatically via [enqueueToolCall]/[enqueueText]/
/// [enqueueToolResultEcho] (a plain FIFO queue). A request arriving with
/// nothing scripted gets an HTTP 500 JSON error, which the adapter
/// surfaces as an error turn (headless exit code 1). `GET .../models`
/// answers a minimal model list; everything else is 404.
///
/// Deterministic: no real LLM, no external network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mock_llm_script.dart';

final class MockLlmServer {
  MockLlmServer._(this._server, this.baseUrl)
    : _model = null,
      _scenarios = const [],
      _fallback = [];

  MockLlmServer._scripted(this._server, this.baseUrl, MockLlmScript script)
    : _model = script.model,
      // Deep-copy the queues: one server instance owns its pops, and the
      // same parsed script stays reusable for a second start().
      _scenarios = [
        for (final scenario in script.scenarios)
          (match: scenario.match, queue: List.of(scenario.responses)),
      ],
      _fallback = List.of(script.responses);

  final HttpServer _server;
  final String? _model;
  final List<({String match, List<MockResponse> queue})> _scenarios;
  final List<MockResponse> _fallback;
  var _chatCalls = 0;
  final _chatBodies = <String>[];

  /// The base URL to pass as the CLI's `--base-url` (trailing `/v1`, so the
  /// adapter's `{baseUrl}/chat/completions` lands on `/v1/chat/completions`).
  final String baseUrl;

  /// The bound loopback port (derived from [baseUrl]).
  int get port => Uri.parse(baseUrl).port;

  /// Starts the server on a loopback ephemeral port with an empty script
  /// (script it programmatically via the `enqueue*` methods), or from a
  /// parsed [script] with scenarios and a fallback queue.
  static Future<MockLlmServer> start({MockLlmScript? script}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = script == null
        ? MockLlmServer._(server, 'http://127.0.0.1:${server.port}/v1')
        : MockLlmServer._scripted(
            server,
            'http://127.0.0.1:${server.port}/v1',
            script,
          );
    server.listen(mock._handle);
    return mock;
  }

  /// How many `/chat/completions` requests were served so far.
  int get chatCalls => _chatCalls;

  /// Raw bodies of the served `/chat/completions` requests, in call order
  /// — lets tests assert on the exact wire payload (e.g. the `tools`
  /// array) without changing any scripted behavior.
  List<String> get chatBodies => List.unmodifiable(_chatBodies);

  /// Scripts the next programmatic response as a streamed tool call.
  void enqueueToolCall(String name, String argumentsJson) {
    _fallback.add(MockToolCall(name, argumentsJson));
  }

  /// Scripts the next programmatic response as a plain assistant text
  /// message.
  void enqueueText(String text) {
    _fallback.add(MockText(text));
  }

  /// Scripts the next programmatic response as assistant text echoing the
  /// last tool result content from the request.
  void enqueueToolResultEcho() {
    _fallback.add(const MockToolResultEcho());
  }

  /// Closes the server and every open connection.
  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path.endsWith('/chat/completions')) {
      await _handleChat(request);
      return;
    }
    if (request.method == 'GET' && path.endsWith('/models')) {
      await _respondJson(request, 200, {
        'object': 'list',
        'data': [
          {'id': _model ?? 'mock-model', 'object': 'model'},
        ],
      });
      return;
    }
    await _respondJson(request, 404, {
      'error': {'message': 'mock: $path'},
    });
  }

  Future<void> _handleChat(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    _chatCalls++;
    _chatBodies.add(body);
    final entry = _nextEntry(body);
    if (entry == null) {
      await _respondJson(request, 500, {
        'error': {'message': 'mock: script exhausted after $_chatCalls calls'},
      });
      return;
    }
    switch (entry) {
      case MockError(:final status, :final message):
        await _respondJson(request, status, {
          'error': {'message': message},
        });
      case MockToolCall(:final name, :final argumentsJson):
        await _respondSse(request, [
          _chunk(_toolCallDelta(name, argumentsJson), null),
          _chunk(const {}, 'tool_calls'),
        ]);
      case MockToolResultEcho():
        await _respondSse(request, [
          _chunk({'content': _lastToolResultText(body)}, null),
          _chunk(const {}, 'stop'),
        ]);
      case MockText(:final text):
        await _respondSse(request, [
          _chunk({'content': text}, null),
          _chunk(const {}, 'stop'),
        ]);
    }
  }

  /// Pops the next scripted response: the first scenario whose [match] is
  /// a substring of the last user message, else the fallback queue. A
  /// matched-but-empty scenario stays exhausted (500) — it owns the
  /// conversation once matched.
  MockResponse? _nextEntry(String body) {
    final user = _lastUserText(body);
    for (final scenario in _scenarios) {
      if (scenario.match.isEmpty || user.contains(scenario.match)) {
        return scenario.queue.isEmpty ? null : scenario.queue.removeAt(0);
      }
    }
    return _fallback.isEmpty ? null : _fallback.removeAt(0);
  }

  /// The text of the last `role: "tool"` message in the request body, or a
  /// marker when the request carried none.
  String _lastToolResultText(String body) {
    final decoded = _decode(body);
    final messages = _messagesOf(decoded);
    for (final message in messages.reversed) {
      if (message is Map && message['role'] == 'tool') {
        return _contentText(message['content']);
      }
    }
    return 'mock: request had no tool result';
  }

  /// The content of the last `role: "user"` message in the request body,
  /// or '' when the request carried none.
  String _lastUserText(String body) {
    final decoded = _decode(body);
    final messages = _messagesOf(decoded);
    for (final message in messages.reversed) {
      if (message is Map && message['role'] == 'user') {
        return _contentText(message['content']);
      }
    }
    return '';
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static List<Object?> _messagesOf(Object? decoded) {
    if (decoded is! Map) return const [];
    final messages = decoded['messages'];
    return messages is List ? messages : const [];
  }

  /// String content rides as-is; OpenAI array content contributes its
  /// `text` parts joined by newlines.
  static String _contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return [
        for (final part in content)
          if (part is Map && part['text'] is String) part['text'] as String,
      ].join('\n');
    }
    return jsonEncode(content);
  }

  Map<String, dynamic> _toolCallDelta(String name, String argumentsJson) {
    return {
      'tool_calls': [
        {
          'index': 0,
          'id': 'call_mock_$_chatCalls',
          'type': 'function',
          'function': {'name': name, 'arguments': argumentsJson},
        },
      ],
    };
  }

  Map<String, dynamic> _chunk(Map<String, dynamic> delta, String? finish) {
    return {
      'id': 'chatcmpl-mock-$_chatCalls',
      'object': 'chat.completion.chunk',
      'model': _model ?? 'mock-model',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };
  }

  Future<void> _respondSse(
    HttpRequest request,
    List<Map<String, dynamic>> chunks,
  ) async {
    request.response.headers.contentType = ContentType('text', 'event-stream');
    final buffer = StringBuffer();
    for (final chunk in chunks) {
      buffer.write('data: ${jsonEncode(chunk)}\n\n');
    }
    buffer.write('data: [DONE]\n\n');
    request.response.write(buffer.toString());
    await request.response.close();
  }

  Future<void> _respondJson(
    HttpRequest request,
    int status,
    Object? body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}
