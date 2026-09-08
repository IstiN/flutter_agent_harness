/// The scripted conversation config for [MockLlmServer]: a YAML or JSON
/// document mapping user messages to queues of responses.
///
/// Document shape (YAML; JSON is a YAML subset, so the same parser takes
/// both):
///
/// ```yaml
/// model: mock-model            # optional, reported by GET /models
/// responses:                   # optional fallback queue, no scenario match
///   - text: "done"
/// scenarios:
///   - match: "list the files"  # substring of the LAST user message
///     responses:               # popped in order, one per request
///       - toolCall:
///           name: bash
///           arguments: '{"command": "ls"}'
///       - toolResultEcho: true
///       - text: "listed"
///       - error: {status: 503, message: "mock outage"}
/// ```
///
/// One response entry per map, keyed by exactly one of:
/// - `text` — assistant text (streamed, `finish_reason: stop`).
/// - `toolCall` — one function call (`name`, `arguments` string or any
///   JSON-encodable value; `finish_reason: tool_calls`).
/// - `toolResultEcho` — echoes the last `role: "tool"` message content
///   back as assistant text (proves a tool result actually flowed).
/// - `error` — HTTP error simulation: `{status: <int>, message: <str>}`
///   (defaults 500 / `mock llm error`), surfaced by adapters as an error
///   turn.
///
/// Routing per `/chat/completions` request: the FIRST scenario whose
/// `match` is a substring of the last user message pops the front of its
/// queue; no match pops the top-level `responses` queue; an empty queue
/// (or no fallback) answers HTTP 500 `script exhausted`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// One scripted response. Subtypes: [MockText], [MockToolCall],
/// [MockToolResultEcho], [MockError].
sealed class MockResponse {
  const MockResponse();
}

/// A plain assistant text message.
final class MockText extends MockResponse {
  const MockText(this.text);

  final String text;
}

/// One streamed function call. [argumentsJson] is the raw JSON argument
/// string sent in the `tool_calls` delta.
final class MockToolCall extends MockResponse {
  const MockToolCall(this.name, this.argumentsJson);

  final String name;
  final String argumentsJson;
}

/// Echoes the last `role: "tool"` message content of the request back as
/// assistant text — the marker a real model quotes the tool result with.
final class MockToolResultEcho extends MockResponse {
  const MockToolResultEcho();
}

/// An error simulation: HTTP [status] with a JSON error [message] body.
final class MockError extends MockResponse {
  const MockError({this.status = 500, this.message = 'mock llm error'});

  final int status;
  final String message;
}

/// One scenario: when [match] occurs in the last user message, the server
/// pops [responses] in order.
final class MockScenario {
  const MockScenario({required this.match, required this.responses});

  /// Substring tested against the last `role: "user"` message content.
  final String match;

  final List<MockResponse> responses;
}

/// A parsed mock script: the reported [model], per-message [scenarios],
/// and the fallback [responses] queue.
final class MockLlmScript {
  const MockLlmScript({
    this.model = 'mock-model',
    this.scenarios = const [],
    this.responses = const [],
  });

  /// Model id reported by `GET /models` and in SSE chunk metadata.
  final String model;

  /// Matched in order; first hit wins.
  final List<MockScenario> scenarios;

  /// Queue popped when no scenario matches.
  final List<MockResponse> responses;

  /// Parses a YAML (or JSON — a YAML subset) script document.
  ///
  /// Throws [MockLlmConfigException] with the offending key path on any
  /// structural problem: strict on purpose — a typo in a test fixture
  /// must fail at startup, not silently fall through to the fallback.
  static MockLlmScript parse(String source) {
    final Object? doc;
    try {
      doc = loadYaml(source);
    } on YamlException catch (error) {
      throw MockLlmConfigException('invalid YAML/JSON: $error');
    }
    return _parseDoc(doc, '');
  }

  /// Parses the script document at [path].
  static MockLlmScript parseFile(String path) =>
      parse(File(path).readAsStringSync());
}

/// A structurally invalid mock script document.
final class MockLlmConfigException implements Exception {
  MockLlmConfigException(this.message);

  final String message;

  @override
  String toString() => 'MockLlmConfigException: $message';
}

MockLlmScript _parseDoc(Object? doc, String path) {
  if (doc is! YamlMap) {
    throw MockLlmConfigException(
      '${_at(path)}expected a mapping at the document root',
    );
  }
  final model = _optString(doc, 'model', path);
  final scenarios = <MockScenario>[];
  final responses = <MockResponse>[];
  for (final key in doc.keys) {
    final keyPath = _join(path, '$key');
    switch (key) {
      case 'model':
        break; // already read
      case 'scenarios':
        final raw = doc[key];
        if (raw is! YamlList) {
          throw MockLlmConfigException('$keyPath must be a list');
        }
        for (var i = 0; i < raw.length; i++) {
          scenarios.add(_parseScenario(raw[i], '$keyPath[$i]'));
        }
      case 'responses':
        responses.addAll(_parseResponses(doc[key], keyPath));
      default:
        throw MockLlmConfigException('${_at(keyPath)}unknown key');
    }
  }
  return MockLlmScript(
    model: model ?? 'mock-model',
    scenarios: List.unmodifiable(scenarios),
    responses: List.unmodifiable(responses),
  );
}

MockScenario _parseScenario(Object? node, String path) {
  if (node is! YamlMap) {
    throw MockLlmConfigException('${_at(path)}expected a mapping');
  }
  final match = _reqString(node, 'match', path);
  final responses = _parseResponses(
    node['responses'],
    _join(path, 'responses'),
  );
  for (final key in node.keys) {
    if (key != 'match' && key != 'responses') {
      throw MockLlmConfigException('${_at(_join(path, '$key'))}unknown key');
    }
  }
  return MockScenario(match: match, responses: responses);
}

List<MockResponse> _parseResponses(Object? node, String path) {
  if (node == null) return const [];
  if (node is! YamlList) {
    throw MockLlmConfigException('${_at(path)}must be a list');
  }
  return [
    for (var i = 0; i < node.length; i++) _parseResponse(node[i], '$path[$i]'),
  ];
}

MockResponse _parseResponse(Object? node, String path) {
  if (node is! YamlMap) {
    throw MockLlmConfigException(
      '${_at(path)}expected a mapping with one of text/toolCall/'
      'toolResultEcho/error',
    );
  }
  if (node.length != 1) {
    throw MockLlmConfigException(
      '${_at(path)}expected exactly one of text/toolCall/toolResultEcho/'
      'error, got [${node.keys.join(', ')}]',
    );
  }
  final key = '${node.keys.first}';
  final value = node.values.first;
  switch (key) {
    case 'text':
      if (value is! String) {
        throw MockLlmConfigException('${_at(path)}text must be a string');
      }
      return MockText(value);
    case 'toolCall':
      if (value is! YamlMap) {
        throw MockLlmConfigException(
          '${_at(path)}toolCall must be a mapping with name/arguments',
        );
      }
      final name = _reqString(value, 'name', '$path.toolCall');
      final arguments = value['arguments'];
      // A string rides verbatim (the wire format); any other value is
      // JSON-encoded so fixture authors can write structured arguments.
      final argumentsJson = arguments is String
          ? arguments
          : jsonEncode(arguments ?? {});
      return MockToolCall(name, argumentsJson);
    case 'toolResultEcho':
      if (value is! bool) {
        throw MockLlmConfigException(
          '${_at(path)}toolResultEcho must be a boolean',
        );
      }
      return const MockToolResultEcho();
    case 'error':
      if (value is! YamlMap) {
        throw MockLlmConfigException(
          '${_at(path)}error must be a mapping with status/message',
        );
      }
      final status = _optInt(value, 'status', '$path.error') ?? 500;
      final message =
          _optString(value, 'message', '$path.error') ?? 'mock llm error';
      for (final errorKey in value.keys) {
        if (errorKey != 'status' && errorKey != 'message') {
          throw MockLlmConfigException(
            '${_at('$path.error.$errorKey')}unknown key',
          );
        }
      }
      return MockError(status: status, message: message);
    default:
      throw MockLlmConfigException(
        '${_at(path)}unknown response kind "$key" (expected text/toolCall/'
        'toolResultEcho/error)',
      );
  }
}

String? _optString(YamlMap map, String key, String path) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw MockLlmConfigException('${_at(_join(path, key))}must be a string');
  }
  return value;
}

String _reqString(YamlMap map, String key, String path) {
  return _optString(map, key, path) ??
      (throw MockLlmConfigException('${_at(_join(path, key))}is required'));
}

int? _optInt(YamlMap map, String key, String path) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int) {
    throw MockLlmConfigException('${_at(_join(path, key))}must be an integer');
  }
  return value;
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

String _at(String path) => path.isEmpty ? '' : '$path: ';
