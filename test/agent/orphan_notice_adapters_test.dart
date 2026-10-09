/// gh-1449 AC2 — per-adapter UT-ROLE: the one-shot orphan note is never a
/// stand-alone user-role turn on ANY provider wire.
///
/// The repair runs BEFORE adaptation and never adds a message (the note
/// rides the payload's last user message as an extra text block); these
/// tests pin the invariant at the adapter boundary for Anthropic, OpenAI
/// chat completions and Google — the repaired payload encodes with the
/// note delivered inside the existing user turn.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

final _at = DateTime.utc(2026);

const _anthropicModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 8192,
);

const _openAiModel = Model(
  id: 'gpt-test',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  contextWindow: 100000,
  maxTokens: 4096,
);

const _googleModel = Model(
  id: 'gemini-test',
  api: 'google-gemini',
  provider: 'google',
  baseUrl: 'https://generativelanguage.googleapis.com',
  contextWindow: 1000000,
  maxTokens: 8192,
);

/// The orphan payload: a result whose originating call is gone, plus a
/// real user turn (the carrier).
Context _orphanContext() => Context(
  messages: [
    UserMessage.text('run the checks', timestamp: _at),
    ToolResultMessage(
      toolCallId: 'bash_198',
      toolName: 'bash',
      content: const [TextContent(text: 'ok')],
      timestamp: _at,
      isError: false,
    ),
  ],
);

/// The payload the agent loop hands the adapter: repaired (AC2's carrier
/// shape decided at the payload level, asserted here on the wire).
Context _repairedContext() =>
    Context(messages: repairToolPairing(_orphanContext().messages).messages);

String _sseNamed(Map<String, dynamic> json) =>
    'event: ${json['type']}\ndata: ${jsonEncode(json)}\n\n';

String _sseData(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

String _anthropicSse() => [
  _sseNamed({
    'type': 'message_start',
    'message': {
      'id': 'msg_1',
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    },
  }),
  _sseNamed({
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  }),
  _sseNamed({
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': 'ack'},
  }),
  _sseNamed({'type': 'content_block_stop', 'index': 0}),
  _sseNamed({
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'output_tokens': 1},
  }),
  _sseNamed({'type': 'message_stop'}),
].join();

String _openAiSse() => [
  _sseData({
    'id': 'chatcmpl-1',
    'choices': [
      {
        'delta': {'content': 'ack'},
      },
    ],
  }),
  _sseData({
    'id': 'chatcmpl-1',
    'choices': [
      {'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
    ],
  }),
  'data: [DONE]\n\n',
].join();

String _googleSse() => _sseData({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': 'ack'},
        ],
        'role': 'model',
      },
      'finishReason': 'STOP',
    },
  ],
  'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1},
});

/// A streaming client that CAPTURES the outgoing request body and answers
/// with [sse].
http.Client _captureClient(List<String> captured, String sse) =>
    http_testing.MockClient.streaming((request, requestBody) async {
      captured.add(utf8.decode(await requestBody.toBytes()));
      return http.StreamedResponse(
        Stream.value(utf8.encode(sse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

/// Runs [invoke] against a capturing client and returns the encoded
/// request body (after asserting the stream completed without an error).
Future<String> _capturedBody(
  AssistantMessageEventStream Function(http.Client client) invoke,
  String sse,
) async {
  final captured = <String>[];
  final events = await invoke(_captureClient(captured, sse)).toList();
  expect(
    events.whereType<ErrorEvent>(),
    isEmpty,
    reason: 'the scripted stream must complete cleanly',
  );
  return captured.single;
}

/// User-turn texts of an Anthropic / OpenAI chat body: one entry per
/// user message, its text blocks joined (the turn is the granularity of
/// AC2, not the block).
List<String> _chatUserTurnTexts(Map<String, dynamic> body) => [
  for (final message in (body['messages'] as List).cast<Map>())
    if (message['role'] == 'user')
      switch (message['content']) {
        final String text => text,
        final List blocks => [
          for (final block in blocks.cast<Map>())
            if (block['type'] == 'text') block['text'] as String,
        ].join('\n'),
        _ => '',
      },
];

/// User-turn texts of a Google `contents` body: one entry per `contents`
/// element, its parts joined.
List<String> _googleUserTurnTexts(Map<String, dynamic> body) => [
  for (final content in (body['contents'] as List).cast<Map>())
    if (content['role'] == 'user')
      [
        for (final part in (content['parts'] as List).cast<Map>())
          if (part['text'] is String) part['text'] as String,
      ].join('\n'),
];

void _expectNoteInsideUserTurn(List<String> turnTexts) {
  // Delivered…
  expect(
    turnTexts.where((t) => t.contains('bash_198')),
    isNotEmpty,
    reason: 'the note must reach the wire',
  );
  // …inside EXACTLY ONE existing user turn (AC2): never a turn of its
  // own. A separate text PART inside the carrier turn is fine — a
  // separate message/contents entry is the regression.
  expect(turnTexts.where((t) => t.contains('[context note:')), hasLength(1));
  for (final text in turnTexts) {
    expect(
      text.trim().startsWith('[context note:'),
      isFalse,
      reason: 'stand-alone note turn on the wire: $text',
    );
  }
}

void main() {
  test('UT-ROLE anthropic: the note rides the existing user message', () async {
    final body = await _capturedBody(
      (client) => streamAnthropic(
        _anthropicModel,
        _repairedContext(),
        const AnthropicOptions(apiKey: '[REDACTED:Sensitive Value]'),
        client,
      ),
      _anthropicSse(),
    );
    _expectNoteInsideUserTurn(_chatUserTurnTexts(jsonDecode(body)));
  });

  test('UT-ROLE openai chat completions: the note rides the existing user '
      'message', () async {
    final body = await _capturedBody(
      (client) => streamOpenAICompletions(
        _openAiModel,
        _repairedContext(),
        const OpenAICompletionsOptions(apiKey: '[REDACTED:Sensitive Value]'),
        client,
      ),
      _openAiSse(),
    );
    _expectNoteInsideUserTurn(_chatUserTurnTexts(jsonDecode(body)));
  });

  test('UT-ROLE google: the note rides the existing user turn', () async {
    final body = await _capturedBody(
      (client) => streamGoogle(
        _googleModel,
        _repairedContext(),
        const GoogleOptions(apiKey: '[REDACTED:Sensitive Value]'),
        client,
      ),
      _googleSse(),
    );
    _expectNoteInsideUserTurn(_googleUserTurnTexts(jsonDecode(body)));
  });
}
