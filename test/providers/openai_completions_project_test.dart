// The CodeMie project header rides the wire from Model.headers (issue
// #1941 AC5): the openai-completions adapter merges the live model's
// headers on EVERY request, so the selected project must be present on
// the serving model — and a model WITHOUT the header must send none (the
// backend's default-project fallback is an ABSENCE semantics, never an
// empty value). Real adapter over MockClient.streaming — no network.
// Split out of openai_completions_test.dart (2800-line gate).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

const _okSse =
    'data: {"id":"1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

Context _simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

Model _codemieModel({Map<String, String>? headers}) => Model(
  id: 'gpt-4o',
  api: 'openai-completions',
  provider: 'codemie',
  baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
  contextWindow: 128000,
  maxTokens: 8192,
  headers: headers,
);

void main() {
  test('the CodeMie project header rides the wire from model.headers '
      '(issue #1941)', () async {
    final requests = <http.BaseRequest>[];
    final client = http_testing.MockClient.streaming((request, body) async {
      requests.add(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode(_okSse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    await streamOpenAICompletions(
      _codemieModel(headers: {'x-codemie-project': 'demo-project'}),
      _simpleContext(),
      const OpenAICompletionsOptions(),
      client,
    ).toList();
    expect(requests.single.headers['x-codemie-project'], 'demo-project');

    // A model WITHOUT the project header sends none — the backend's
    // default-project fallback is the ABSENCE semantics, never an empty
    // value.
    await streamOpenAICompletions(
      _codemieModel(),
      _simpleContext(),
      const OpenAICompletionsOptions(apiKey: 'k'),
      client,
    ).toList();
    expect(requests.last.headers.containsKey('x-codemie-project'), isFalse);
  });

  test('the client header rides every CodeMie chat request via the '
      'defaults slot (issue #2426 AC2)', () async {
    final requests = <http.BaseRequest>[];
    final client = http_testing.MockClient.streaming((request, body) async {
      requests.add(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode(_okSse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    // SSO-cookie leg (cookie rides model.headers, no Bearer).
    await streamOpenAICompletions(
      _codemieModel(headers: {'cookie': 'k=v'}),
      _simpleContext(),
      const OpenAICompletionsOptions(),
      client,
    ).toList();
    expect(requests.single.headers['x-codemie-client'], codeMieClient);
    expect(requests.single.headers['cookie'], 'k=v');

    // JWT Bearer leg (regular auth path, no model headers at all — the
    // defaults slot alone carries the client header).
    await streamOpenAICompletions(
      _codemieModel(),
      _simpleContext(),
      const OpenAICompletionsOptions(apiKey: 'jwt-token'),
      client,
    ).toList();
    expect(requests.last.headers['x-codemie-client'], codeMieClient);
  });

  test('a non-CodeMie endpoint carries none of the CodeMie headers '
      '(issue #2426 AC4 / INV-3)', () async {
    final requests = <http.BaseRequest>[];
    final client = http_testing.MockClient.streaming((request, body) async {
      requests.add(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode(_okSse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final plain = Model(
      id: 'gpt-4o',
      api: 'openai-completions',
      provider: 'openai',
      baseUrl: 'https://api.openai.example/v1',
      contextWindow: 128000,
      maxTokens: 8192,
    );
    await streamOpenAICompletions(
      plain,
      _simpleContext(),
      const OpenAICompletionsOptions(apiKey: 'sk'),
      client,
    ).toList();
    expect(requests.single.headers.containsKey('x-codemie-client'), isFalse);
    expect(requests.single.headers.containsKey('x-codemie-project'), isFalse);

    // A custom provider whose BASE URL is CodeMie rides the same gate —
    // the URL decides, not the provider name.
    final customCodemie = Model(
      id: 'm',
      api: 'openai-completions',
      provider: 'openai',
      baseUrl: 'https://codemy-org.example.com/code-assistant-api/v1',
      contextWindow: 128000,
      maxTokens: 8192,
    );
    await streamOpenAICompletions(
      customCodemie,
      _simpleContext(),
      const OpenAICompletionsOptions(apiKey: 'k'),
      client,
    ).toList();
    expect(requests.last.headers['x-codemie-client'], codeMieClient);
  });

  test('an explicit user entry overrides the client header default '
      '(issue #2426 AC5 / INV-2)', () async {
    final requests = <http.BaseRequest>[];
    final client = http_testing.MockClient.streaming((request, body) async {
      requests.add(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode(_okSse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    await streamOpenAICompletions(
      _codemieModel(headers: {codeMieClientHeader: 'my-org-client'}),
      _simpleContext(),
      const OpenAICompletionsOptions(),
      client,
    ).toList();
    expect(requests.single.headers['x-codemie-client'], 'my-org-client');

    // A null options entry suppresses the default (pi's ProviderHeaders
    // semantics).
    await streamOpenAICompletions(
      _codemieModel(),
      _simpleContext(),
      const OpenAICompletionsOptions(headers: {codeMieClientHeader: null}),
      client,
    ).toList();
    expect(requests.last.headers.containsKey(codeMieClientHeader), isFalse);
  });
}
