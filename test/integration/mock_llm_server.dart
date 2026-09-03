/// Scripted OpenAI-compatible mock LLM server for integration tests.
///
/// Binds a loopback HTTP server on an ephemeral port and answers
/// `POST <baseUrl>/chat/completions` (the exact path
/// `streamOpenAICompletions` builds: `{model.baseUrl}/chat/completions`)
/// with OpenAI-style SSE chunks carrying the scripted responses, in call
/// order:
///
/// - [enqueueToolCall]: one streamed `tool_calls` delta plus
///   `finish_reason: "tool_calls"`.
/// - [enqueueText]: one `content` delta plus `finish_reason: "stop"`.
/// - [enqueueToolResultEcho]: a `content` response echoing back the text of
///   the last `role: "tool"` message in the request (what a real model would
///   quote); proves the tool result actually flowed through the sandbox.
///
/// A request arriving with an empty script gets an HTTP 500 JSON error,
/// which the adapter surfaces as an error turn (headless exit code 1).
/// `GET .../models` answers a minimal model list; everything else is 404.
///
/// Deterministic: no real LLM, no external network. `dart:io` is allowed
/// under `test/`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One scripted response entry.
sealed class _ScriptEntry {
  const _ScriptEntry();
}

final class _ToolCallEntry extends _ScriptEntry {
  const _ToolCallEntry(this.name, this.argumentsJson);
  final String name;
  final String argumentsJson;
}

final class _TextEntry extends _ScriptEntry {
  const _TextEntry(this.text);
  final String text;
}

final class _ToolResultEchoEntry extends _ScriptEntry {
  const _ToolResultEchoEntry();
}

final class MockLlmServer {
  MockLlmServer._(this._server, this.baseUrl);

  final HttpServer _server;
  final _script = <_ScriptEntry>[];
  var _chatCalls = 0;
  final _chatBodies = <String>[];

  /// The base URL to pass as the CLI's `--base-url` (trailing `/v1`, so the
  /// adapter's `{baseUrl}/chat/completions` lands on `/v1/chat/completions`).
  final String baseUrl;

  /// The bound loopback port (derived from [baseUrl]).
  int get port => Uri.parse(baseUrl).port;

  /// Starts the server on a loopback ephemeral port.
  static Future<MockLlmServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = MockLlmServer._(server, 'http://127.0.0.1:${server.port}/v1');
    server.listen(mock._handle);
    return mock;
  }

  /// How many `/chat/completions` requests were served so far.
  int get chatCalls => _chatCalls;

  /// Raw bodies of the served `/chat/completions` requests, in call order
  /// — lets tests assert on the exact wire payload (e.g. the `tools`
  /// array) without changing any scripted behavior.
  List<String> get chatBodies => List.unmodifiable(_chatBodies);

  /// Scripts the next response as a streamed tool call.
  void enqueueToolCall(String name, String argumentsJson) {
    _script.add(_ToolCallEntry(name, argumentsJson));
  }

  /// Scripts the next response as a plain assistant text message.
  void enqueueText(String text) {
    _script.add(_TextEntry(text));
  }

  /// Scripts the next response as assistant text echoing the last tool
  /// result content from the request.
  void enqueueToolResultEcho() {
    _script.add(const _ToolResultEchoEntry());
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
          {'id': 'mock-model', 'object': 'model'},
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
    final entry = _script.isEmpty ? null : _script.removeAt(0);
    if (entry == null) {
      await _respondJson(request, 500, {
        'error': {'message': 'mock: script exhausted after $_chatCalls calls'},
      });
      return;
    }
    final text = switch (entry) {
      _ToolResultEchoEntry() => _lastToolResultText(body),
      _TextEntry(:final text) => text,
      _ToolCallEntry() => null,
    };
    if (entry is _ToolCallEntry) {
      await _respondSse(request, [
        _chunk(_toolCallDelta(entry.name, entry.argumentsJson), null),
        _chunk(const {}, 'tool_calls'),
      ]);
      return;
    }
    await _respondSse(request, [
      _chunk({'content': text}, null),
      _chunk(const {}, 'stop'),
    ]);
  }

  /// The text of the last `role: "tool"` message in the request body, or a
  /// marker when the request carried none.
  String _lastToolResultText(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return 'mock: undecodable request body';
    }
    final messages = decoded is Map ? decoded['messages'] : null;
    if (messages is! List) return 'mock: request had no messages';
    for (final message in messages.reversed) {
      if (message is Map && message['role'] == 'tool') {
        return '${message['content']}';
      }
    }
    return 'mock: request had no tool result';
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
      'model': 'mock-model',
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
