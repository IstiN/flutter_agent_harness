import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Audio → `input_audio` wire-format coverage for the OpenAI-completions
/// dialect. Lives in its own file because the main
/// openai_completions_test.dart sits against the 2800-line loc ratchet
/// (crap4dart.loc-scope.yaml, whole-tree in the guards job).

const okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

final testModel = Model(
  id: 'gpt-4o-mini',
  name: 'GPT-4o mini',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  input: const ['text', 'image'],
  contextWindow: 128000,
  maxTokens: 16384,
  cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
);

void main() {
  /// Streams [context] through a capturing client and returns the decoded
  /// request body.
  Future<Map<String, dynamic>> sentBody(Model model, Context context) async {
    Map<String, dynamic>? body;
    final client = http_testing.MockClient.streaming((
      request,
      requestBody,
    ) async {
      body =
          jsonDecode(await requestBody.bytesToString()) as Map<String, dynamic>;
      return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
    });
    final stream = streamOpenAICompletions(
      model,
      context,
      const OpenAICompletionsOptions(apiKey: '[REDACTED:Sensitive Value]'),
      client,
    );
    await stream.result;
    return body!;
  }

  List<dynamic> messagesOf(Map<String, dynamic> body) =>
      body['messages'] as List<dynamic>;

  test('user AudioContent becomes input_audio (OpenRouter dialect)', () async {
    final body = await sentBody(
      testModel,
      Context(
        messages: [
          UserMessage(
            content: const [
              TextContent(text: 'What do you hear?'),
              AudioContent(data: 'aGk=', mimeType: 'audio/mp4'),
            ],
            timestamp: DateTime.utc(2026),
          ),
        ],
      ),
    );
    final messages = messagesOf(body);
    expect(messages.last, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'What do you hear?'},
        {
          'type': 'input_audio',
          'input_audio': {'data': 'aGk=', 'format': 'm4a'},
        },
      ],
    });
  });

  test('every audio mime type maps to its input_audio format tag', () async {
    // Exhaustive wire-format table for `_openAiAudioFormat`: each
    // documented mapping, both spellings where the dialect accepts two,
    // case-insensitive keys, and the unknown-mime fallback. Guards the
    // full mapping matrix — the CRAP gate flagged this helper as the
    // worst-complexity spot (CC 13) with most branches untested.
    final cases = <String, String>{
      'audio/mpeg': 'mp3',
      'audio/mp3': 'mp3',
      'audio/wav': 'wav',
      'audio/x-wav': 'wav',
      'audio/mp4': 'm4a',
      'audio/x-m4a': 'm4a',
      'audio/m4a': 'm4a',
      'audio/aac': 'aac',
      'audio/x-aac': 'aac',
      'audio/flac': 'flac',
      'audio/ogg': 'ogg',
      // Unknown mime types fall back to the OpenAI-documented mp3 tag.
      'audio/x-hidden': 'mp3',
      'application/octet-stream': 'mp3',
    };
    for (final entry in cases.entries) {
      final body = await sentBody(
        testModel,
        Context(
          messages: [
            UserMessage(
              content: [AudioContent(data: 'aGk=', mimeType: entry.key)],
              timestamp: DateTime.utc(2026),
            ),
          ],
        ),
      );
      final part = (messagesOf(body).last['content'] as List).last;
      expect(
        part['input_audio']['format'],
        entry.value,
        reason: '${entry.key} must map to ${entry.value}',
      );
    }
  });

  test('audio mime mapping is case-insensitive', () async {
    for (final mime in const ['AUDIO/WAV', 'Audio/FLAC', 'AUDIO/OGG']) {
      final body = await sentBody(
        testModel,
        Context(
          messages: [
            UserMessage(
              content: [AudioContent(data: 'aGk=', mimeType: mime)],
              timestamp: DateTime.utc(2026),
            ),
          ],
        ),
      );
      final part = (messagesOf(body).last['content'] as List).last;
      expect(
        part['input_audio']['format'],
        isNot('mp3'),
        reason: '$mime must keep its own tag, not fall back',
      );
    }
  });
}
