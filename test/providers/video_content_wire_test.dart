import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// gh-1985 AC1 — `VideoContent` provider shaping: google-shaped inline
/// video, openai-completions per its (`video_url`) shape, Anthropic skips
/// defensively (errors-as-events invariant: no provider throws), and the
/// text-only downgrade produces the standard omission note.

const okSse =
    'data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}\n\n'
    'data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

const googleOkChunk =
    'data: {"candidates":[{"content":{"parts":[{"text":"ok"}],"role":"model"},'
    '"finishReason":"STOP"}],"usageMetadata":{"totalTokenCount":2}}\n\n';

const anthropicOkSse =
    'event: message_start\n'
    'data: {"type":"message_start","message":{"role":"assistant"}}\n\n'
    'event: content_block_start\n'
    'data: {"type":"content_block_start","index":0,'
    '"content_block":{"type":"text","text":""}}\n\n'
    'event: content_block_delta\n'
    'data: {"type":"content_block_delta","index":0,'
    '"delta":{"type":"text_delta","text":"ok"}}\n\n'
    'event: content_block_stop\n'
    'data: {"type":"content_block_stop","index":0}\n\n'
    'event: message_delta\n'
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n'
    'event: message_stop\n'
    'data: {"type":"message_stop"}\n\n';

final videoModel = Model(
  id: 'glm-5.3-flash',
  name: 'GLM 5.3 Flash',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  input: const ['text', 'image', 'video'],
  contextWindow: 128000,
  maxTokens: 16384,
);

Context videoContext({List<ContentBlock>? content}) => Context(
  messages: [
    UserMessage(
      content:
          content ??
          const [
            TextContent(text: 'Describe this video.'),
            VideoContent(data: 'aGk=', mimeType: 'video/mp4'),
          ],
      timestamp: DateTime.utc(2026),
    ),
  ],
);

/// Streams [context] through a capturing client and returns the decoded
/// request body.
Future<Map<String, dynamic>> openAiBody(Model model, Context context) async {
  Map<String, dynamic>? body;
  final client = http_testing.MockClient.streaming((request, bodyStream) async {
    body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(Stream.value(utf8.encode(okSse)), 200);
  });
  final stream = streamOpenAICompletions(
    model,
    context,
    const OpenAICompletionsOptions(apiKey: 'sk-test'),
    client,
  );
  await stream.result;
  return body!;
}

Future<Map<String, dynamic>> googleBody(Model model, Context context) async {
  Map<String, dynamic>? body;
  final client = http_testing.MockClient.streaming((request, bodyStream) async {
    body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(googleOkChunk)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  final stream = streamGoogle(
    model,
    context,
    const GoogleOptions(apiKey: 'g-test'),
    client,
  );
  await stream.result;
  return body!;
}

Future<Map<String, dynamic>> anthropicBody(Model model, Context context) async {
  Map<String, dynamic>? body;
  final client = http_testing.MockClient.streaming((request, bodyStream) async {
    body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
    return http.StreamedResponse(
      Stream.value(utf8.encode(anthropicOkSse)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
  final stream = streamAnthropic(
    model,
    context,
    const AnthropicOptions(apiKey: 'a-test'),
    client,
  );
  await stream.result;
  return body!;
}

void main() {
  group('VideoContent serialization', () {
    test('round-trips through toJson/fromJson with the video discriminator', () {
      const block = VideoContent(data: 'aGk=', mimeType: 'video/mp4');
      final json = block.toJson();
      expect(json['type'], 'video');
      final decoded = ContentBlock.fromJson(json);
      expect(decoded, isA<VideoContent>());
      final video = decoded as VideoContent;
      expect(video.data, 'aGk=');
      expect(video.mimeType, 'video/mp4');
    });
  });

  group('openai-completions shaping', () {
    test('video rides as video_url with a data URL on a video-capable model',
        () async {
      final body = await openAiBody(videoModel, videoContext());
      final messages = body['messages'] as List<dynamic>;
      expect(messages.last, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Describe this video.'},
          {
            'type': 'video_url',
            'video_url': {'url': 'data:video/mp4;base64,aGk='},
          },
        ],
      });
    });

    test('tool-result videos ride the Attached video(s) turn on a '
        'video-capable model', () async {
      final body = await openAiBody(
        videoModel,
        Context(
          messages: [
            UserMessage.text('read it', timestamp: DateTime.utc(2026)),
            AssistantMessage(
              content: const [
                TextContent(text: 'ok'),
                ToolCall(id: 'call_1', name: 'read', arguments: {}),
              ],
              api: 'openai-completions',
              provider: 'openrouter',
              model: 'glm-5.3-flash',
              usage: Usage.zero,
              stopReason: StopReason.toolUse,
              timestamp: DateTime.utc(2026),
            ),
            ToolResultMessage(
              toolCallId: 'call_1',
              toolName: 'read',
              isError: false,
              content: const [
                TextContent(text: '[Video: clip.mp4]'),
                VideoContent(data: 'aGk=', mimeType: 'video/mp4'),
              ],
              timestamp: DateTime.utc(2026),
            ),
          ],
        ),
      );
      final messages = body['messages'] as List<dynamic>;
      final attached = messages
          .whereType<Map<String, dynamic>>()
          .where(
            (message) =>
                (message['content'] is List) &&
                (message['content'] as List).any(
                  (part) =>
                      part is Map<String, dynamic> &&
                      part['type'] == 'video_url',
                ),
          )
          .toList();
      expect(attached, hasLength(1));
      expect(
        (attached.single['content'] as List).first,
        {
          'type': 'text',
          'text': 'Attached video(s) from tool result:',
        },
      );
    });

    test('a no-video model downgrades the block to the omission note', () async {
      final body = await openAiBody(
        Model(
          id: 'gpt-4o-mini',
          name: 'GPT-4o mini',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          input: const ['text', 'image'],
          contextWindow: 128000,
          maxTokens: 16384,
        ),
        videoContext(),
      );
      final messages = body['messages'] as List<dynamic>;
      final content = (messages.last['content'] as List<dynamic>);
      expect(
        content.whereType<Map<String, dynamic>>().any(
          (part) => part['type'] == 'video_url',
        ),
        isFalse,
      );
      expect(
        content.any(
          (part) =>
              part is Map<String, dynamic> &&
              (part['text'] as String?)!.contains('video omitted'),
        ),
        isTrue,
      );
    });
  });

  group('google shaping', () {
    final googleVideoModel = Model(
      id: 'gemini-2.5-flash',
      name: 'Gemini 2.5 Flash',
      api: 'google-generative-ai',
      provider: 'google',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      input: const ['text', 'image', 'video'],
      contextWindow: 1000000,
      maxTokens: 65536,
    );

    test('video rides as inlineData on a video-capable model', () async {
      final body = await googleBody(googleVideoModel, videoContext());
      final contents = body['contents'] as List<dynamic>;
      final parts =
          (contents.last['parts'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .toList();
      expect(
        parts.any(
          (part) =>
              part['inlineData'] != null &&
              (part['inlineData'] as Map<String, dynamic>)['mimeType'] ==
                  'video/mp4' &&
              (part['inlineData'] as Map<String, dynamic>)['data'] == 'aGk=',
        ),
        isTrue,
        reason: 'expected an inlineData video part, got: $parts',
      );
    });

    test('a no-video google model downgrades the block to the omission note',
        () async {
      final body = await googleBody(
        Model(
          id: 'gemini-2.5-flash',
          name: 'Gemini 2.5 Flash',
          api: 'google-generative-ai',
          provider: 'google',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          input: const ['text', 'image'],
          contextWindow: 1000000,
          maxTokens: 65536,
        ),
        videoContext(),
      );
      final contents = body['contents'] as List<dynamic>;
      final parts =
          (contents.last['parts'] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .toList();
      expect(
        parts.every((part) => part['inlineData'] == null),
        isTrue,
        reason: 'video must be stripped, got: $parts',
      );
      expect(
        parts.any(
          (part) => (part['text'] as String?)!.contains('video omitted'),
        ),
        isTrue,
      );
    });
  });

  group('anthropic (no video input)', () {
    final anthropicModel = Model(
      id: 'claude-sonnet-4',
      name: 'Claude Sonnet 4',
      api: 'anthropic-messages',
      provider: 'anthropic',
      baseUrl: 'https://api.anthropic.com',
      input: const ['text', 'image'],
      contextWindow: 200000,
      maxTokens: 65536,
    );

    test('skips the video block defensively and never throws', () async {
      final body = await anthropicBody(anthropicModel, videoContext());
      final messages = body['messages'] as List<dynamic>;
      final content = messages.last['content'] as List<dynamic>;
      expect(
        content.any(
          (block) =>
              block is Map<String, dynamic> && block['type'] != 'text',
        ),
        isFalse,
        reason: 'no non-text block may reach the Anthropic wire: $content',
      );
    });
  });

  group('downgradeUnsupportedImages (video)', () {
    test('user video → the user video placeholder; notice counts it', () {
      final dropped = <int>[];
      final previous = textOnlyImageDropNotice;
      textOnlyImageDropNotice = (count) => dropped.add(count);
      try {
        final model = Model(
          id: 'text-only',
          name: 'text-only',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          input: const ['text'],
          contextWindow: 128000,
          maxTokens: 16384,
        );
        final messages = videoContext().messages;
        final out = downgradeUnsupportedImages(messages, model);
        final user = out.single as UserMessage;
        final blocks = user.content as List<ContentBlock>;
        expect(
          blocks.any((block) => block is VideoContent),
          isFalse,
        );
        expect(
          blocks.any(
            (block) =>
                block is TextContent &&
                block.text == nonVisionUserVideoPlaceholder,
          ),
          isTrue,
        );
        expect(dropped, [1]);
      } finally {
        textOnlyImageDropNotice = previous;
      }
    });

    test('tool-result video → the tool video placeholder', () {
      final model = Model(
        id: 'text-only',
        name: 'text-only',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        input: const ['text'],
        contextWindow: 128000,
        maxTokens: 16384,
      );
      final out = downgradeUnsupportedImages([
        ToolResultMessage(
          toolCallId: 'call_1',
          toolName: 'read',
          isError: false,
          content: const [
            TextContent(text: '[Video: clip.mp4]'),
            VideoContent(data: 'aGk=', mimeType: 'video/mp4'),
          ],
          timestamp: DateTime.utc(2026),
        ),
      ], model);
      final tool = out.single as ToolResultMessage;
      expect(
        tool.content.any((block) => block is VideoContent),
        isFalse,
      );
      expect(
        tool.content.any(
          (block) =>
              block is TextContent &&
              block.text == nonVisionToolVideoPlaceholder,
        ),
        isTrue,
      );
    });

    test('a video-capable model keeps the block (REG: no rewrite)', () {
      final out = downgradeUnsupportedImages(
        videoContext().messages,
        videoModel,
      );
      final user = out.single as UserMessage;
      expect(
        (user.content as List<ContentBlock>).any((block) => block is VideoContent),
        isTrue,
      );
    });
  });
}
