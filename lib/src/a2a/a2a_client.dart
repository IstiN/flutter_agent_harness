/// A2A (Agent2Agent) protocol — Google's agent-to-agent standard.
///
/// Pure-Dart core (no dart:io): Agent Card parsing, JSON-RPC codec,
/// Task lifecycle types, and the client over injectable `package:http`.
/// The server transport lives in `bin/` + `lib/io.dart` (same split as MCP).
///
/// Protocol facts (v1.0, verified 2026-08-09):
/// - Transport: JSON-RPC 2.0 over HTTP, SSE for streaming
/// - Discovery: Agent Card at `/.well-known/agent.json`
/// - Methods: `message/send`, `message/stream`, `tasks/get`, `tasks/cancel`
/// - Task lifecycle: submitted → working → input-required → completed/failed
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Agent Card
// ---------------------------------------------------------------------------

/// The capabilities an A2A agent advertises in its Agent Card.
final class AgentCard {
  const AgentCard({
    required this.name,
    required this.description,
    required this.url,
    this.version = '1.0.0',
    this.skills = const [],
    this.modalities = const ['text'],
    this.authSchemes = const [],
  });

  factory AgentCard.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'] as Map<String, dynamic>?;
    return AgentCard(
      name: json['name'] as String? ?? 'unknown',
      description: json['description'] as String? ?? '',
      url: json['url'] as String? ?? '',
      version: json['version'] as String? ?? '1.0.0',
      skills:
          (json['skills'] as List?)
              ?.map((s) => AgentSkill.fromJson(s as Map<String, dynamic>))
              .toList() ??
          const [],
      modalities:
          (capabilities?['inputModes'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['text'],
      authSchemes:
          (json['authentication'] as Map<String, dynamic>?)?.values
              .map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  final String name;
  final String description;
  final String url;
  final String version;
  final List<AgentSkill> skills;
  final List<String> modalities;
  final List<String> authSchemes;
}

/// One skill advertised in the Agent Card.
final class AgentSkill {
  const AgentSkill({
    required this.id,
    required this.name,
    this.description = '',
  });

  factory AgentSkill.fromJson(Map<String, dynamic> json) => AgentSkill(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );

  final String id;
  final String name;
  final String description;
}

// ---------------------------------------------------------------------------
// Task lifecycle
// ---------------------------------------------------------------------------

/// A2A Task states.
enum A2aTaskState {
  submitted,
  working,
  inputRequired, // "input-required" in the spec
  completed,
  failed,
  canceled;

  static A2aTaskState fromString(String s) => switch (s) {
    'submitted' => submitted,
    'working' => working,
    'input-required' => inputRequired,
    'completed' => completed,
    'failed' => failed,
    'canceled' => canceled,
    _ => working,
  };

  String toSpecString() => switch (this) {
    submitted => 'submitted',
    working => 'working',
    inputRequired => 'input-required',
    completed => 'completed',
    failed => 'failed',
    canceled => 'canceled',
  };
}

/// A2A Task: a stateful unit of work with messages and artifacts.
final class A2aTask {
  A2aTask({
    required this.id,
    required this.state,
    this.messages = const [],
    this.artifacts = const [],
  });

  factory A2aTask.fromJson(Map<String, dynamic> json) => A2aTask(
    id: json['id'] as String,
    state: A2aTaskState.fromString(
      json['status']?['state'] as String? ?? 'working',
    ),
    messages:
        (json['messages'] as List?)
            ?.map((m) => A2aMessage.fromJson(m as Map<String, dynamic>))
            .toList() ??
        const [],
    artifacts:
        (json['artifacts'] as List?)
            ?.map((a) => A2aArtifact.fromJson(a as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  final String id;
  A2aTaskState state;
  List<A2aMessage> messages;
  List<A2aArtifact> artifacts;
}

/// A message part: text or structured data.
final class A2aPart {
  const A2aPart({this.text, this.data});
  factory A2aPart.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('text')) {
      return A2aPart(text: json['text'] as String);
    }
    return A2aPart(data: json);
  }

  final String? text;
  final Map<String, dynamic>? data;

  Map<String, dynamic> toJson() => text != null
      ? {'type': 'text', 'text': text}
      : {'type': 'data', ...?data};
}

/// A message in an A2A task.
final class A2aMessage {
  const A2aMessage({required this.role, required this.parts});
  factory A2aMessage.fromJson(Map<String, dynamic> json) => A2aMessage(
    role: json['role'] as String? ?? 'user',
    parts:
        (json['parts'] as List?)
            ?.map((p) => A2aPart.fromJson(p as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  final String role;
  final List<A2aPart> parts;

  String get textContent =>
      parts.where((p) => p.text != null).map((p) => p.text!).join('\n');

  Map<String, dynamic> toJson() => {
    'role': role,
    'parts': [for (final p in parts) p.toJson()],
  };
}

/// A task artifact (output).
final class A2aArtifact {
  const A2aArtifact({this.parts = const []});
  factory A2aArtifact.fromJson(Map<String, dynamic> json) => A2aArtifact(
    parts:
        (json['parts'] as List?)
            ?.map((p) => A2aPart.fromJson(p as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  final List<A2aPart> parts;

  String get textContent =>
      parts.where((p) => p.text != null).map((p) => p.text!).join('\n');
}

// ---------------------------------------------------------------------------
// JSON-RPC codec
// ---------------------------------------------------------------------------

/// Builds a JSON-RPC 2.0 request envelope.
Map<String, dynamic> _rpcRequest(
  String method,
  Map<String, dynamic> params, {
  int id = 1,
}) => {'jsonrpc': '2.0', 'method': method, 'params': params, 'id': id};

/// Parses a JSON-RPC 2.0 response, returning the result or throwing.
Map<String, dynamic> _rpcResult(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw FormatException('not a JSON object');
  if (decoded['error'] != null) {
    final error = decoded['error'];
    throw A2aException(
      error is Map ? error['message']?.toString() ?? 'A2A error' : 'A2A error',
    );
  }
  return decoded['result'] as Map<String, dynamic>? ?? {};
}

/// Thrown on A2A protocol errors.
final class A2aException implements Exception {
  const A2aException(this.message);
  final String message;
  @override
  String toString() => 'A2aException: $message';
}

// ---------------------------------------------------------------------------
// A2A Client
// ---------------------------------------------------------------------------

/// An A2A client: discovers agents, sends messages, streams responses,
/// and manages task lifecycles — all over injectable `package:http`.
final class A2aClient {
  A2aClient({required this.baseUrl, this.token, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final String? token;
  final http.Client _client;
  AgentCard? _card;

  /// Fetches and caches the Agent Card from `/.well-known/agent.json`.
  Future<AgentCard> get card async {
    if (_card != null) return _card!;
    final response = await _client.get(
      Uri.parse('$baseUrl/.well-known/agent.json'),
      headers: _headers(),
    );
    if (response.statusCode != 200) {
      throw A2aException('Agent Card fetch failed (${response.statusCode})');
    }
    _card = AgentCard.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    return _card!;
  }

  /// Sends a message to the agent (non-streaming). Returns the task.
  Future<A2aTask> sendMessage(String text) async {
    final response = await _client.post(
      Uri.parse(baseUrl),
      headers: _headers(),
      body: jsonEncode(
        _rpcRequest('message/send', {
          'message': {
            'role': 'user',
            'parts': [
              {'type': 'text', 'text': text},
            ],
          },
        }),
      ),
    );
    final result = _rpcResult(response.body);
    return A2aTask.fromJson(result);
  }

  /// Streams a message via SSE. Yields task state updates as they arrive.
  Stream<A2aTask> streamMessage(String text) async* {
    final request = http.Request('POST', Uri.parse(baseUrl))
      ..headers.addAll(_headers(accept: 'text/event-stream'))
      ..body = jsonEncode(
        _rpcRequest('message/stream', {
          'message': {
            'role': 'user',
            'parts': [
              {'type': 'text', 'text': text},
            ],
          },
        }),
      );
    final response = await _client.send(request);
    await for (final chunk
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!chunk.startsWith('data: ')) continue;
      final data = chunk.substring(6).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) {
          final result = decoded['result'] as Map<String, dynamic>?;
          if (result != null) {
            yield A2aTask.fromJson(result);
          }
        }
      } on Object {
        // Skip malformed SSE lines.
      }
    }
  }

  /// Gets the current state of a task.
  Future<A2aTask> getTask(String taskId) async {
    final response = await _client.post(
      Uri.parse(baseUrl),
      headers: _headers(),
      body: jsonEncode(_rpcRequest('tasks/get', {'taskId': taskId})),
    );
    return A2aTask.fromJson(_rpcResult(response.body));
  }

  /// Cancels a task.
  Future<A2aTask> cancelTask(String taskId) async {
    final response = await _client.post(
      Uri.parse(baseUrl),
      headers: _headers(),
      body: jsonEncode(_rpcRequest('tasks/cancel', {'taskId': taskId})),
    );
    return A2aTask.fromJson(_rpcResult(response.body));
  }

  void close() => _client.close();

  Map<String, String> _headers({String accept = 'application/json'}) {
    return {
      'content-type': 'application/json',
      'accept': accept,
      if (token != null) 'authorization': 'Bearer $token',
    };
  }
}
