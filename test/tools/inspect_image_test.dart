import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:image/image.dart';
import 'package:test/test.dart';

Uint8List _makePng() {
  final img = Image(width: 2, height: 2)..getPixel(0, 0).r = 255;
  return Uint8List.fromList(encodePng(img));
}

http.Client _fakeVisionClient(String content) {
  return http_testing.MockClient.streaming((request, bodyStream) async {
    final payload = jsonEncode({
      'id': 'chatcmpl-test',
      'object': 'chat.completion.chunk',
      'created': 1234567890,
      'model': 'gpt-4o',
      'choices': [
        {
          'index': 0,
          'delta': {'role': 'assistant', 'content': content},
          'finish_reason': null,
        },
      ],
    });
    final done = jsonEncode({
      'id': 'chatcmpl-test',
      'object': 'chat.completion.chunk',
      'created': 1234567890,
      'model': 'gpt-4o',
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
      ],
    });
    final sse = Stream.fromIterable(['data: $payload\n\n', 'data: $done\n\n']);
    return http.StreamedResponse(
      sse.transform(utf8.encoder),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

void main() {
  group('inspectImageTool', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv();
    });

    test('describes an image using a vision model', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'vision-key',
        httpClient: _fakeVisionClient('A small red pixel.'),
      );
      final tool = inspectImageTool(env, config);
      final result = await tool.execute(
        {'path': '/work/shot.png', 'prompt': 'What is in this image?'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'A small red pixel.');
    });

    test('uses default prompt when none is supplied', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'vision-key',
        httpClient: _fakeVisionClient('A tiny image.'),
      );
      final tool = inspectImageTool(env, config);
      final result = await tool.execute({'path': '/work/shot.png'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'A tiny image.');
    });

    test('throws when the file is missing', () async {
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'vision-key',
      );
      final tool = inspectImageTool(env, config);
      expect(
        tool.execute({'path': '/work/missing.png'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('throws for a non-image file', () async {
      await env.writeFile('/work/notes.txt', 'just text');
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'vision-key',
      );
      final tool = inspectImageTool(env, config);
      expect(
        tool.execute({'path': '/work/notes.txt'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported image format'),
          ),
        ),
      );
    });

    test(
      'refuses the chatgpt-codex kind with a named error (gh-760 sweep)',
      () async {
        // The Codex Responses adapter has no vision wire; the old `_ =>`
        // fallback silently misrouted this kind's vision calls to
        // api.openai.com. Refuse loudly instead.
        await env.writeBinaryFile('/work/shot.png', _makePng());
        final config = InspectImageConfig(
          modelId: 'gpt-5-codex',
          apiKey: 'test-key',
          providerKind: 'chatgpt-codex',
        );
        final tool = inspectImageTool(env, config);
        expect(
          tool.execute({'path': '/work/shot.png'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf([contains('chatgpt-codex'), contains('vision')]),
            ),
          ),
        );
      },
    );

    test('throws when the vision model returns an error event', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final client = http_testing.MockClient.streaming((
        request,
        bodyStream,
      ) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            'data: {"error":{"message":"Invalid API key","type":"invalid_request_error"}}\n\n',
          ]).transform(utf8.encoder),
          401,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: 'vision-key',
        httpClient: client,
      );
      final tool = inspectImageTool(env, config);
      expect(
        tool.execute({'path': '/work/shot.png'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Vision model error'),
          ),
        ),
      );
    });

    test('forwards a mid-stream cancel to the vision call (AC6)', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final source = CancelTokenSource();
      // The endpoint streams slowly: the cancel lands MID-STREAM, which
      // only aborts when the tool forwards the token into the shared
      // vision helper (pre-call checkpoints cannot see it).
      final client = http_testing.MockClient.streaming((request, body) async {
        final chunk =
            'data: ${jsonEncode({
              'id': 'c',
              'object': 'chat.completion.chunk',
              'created': 1,
              'model': 'gpt-4o',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'partial'},
                  'finish_reason': null,
                },
              ],
            })}\n\n';
        final done =
            'data: ${jsonEncode({
              'id': 'c',
              'object': 'chat.completion.chunk',
              'created': 1,
              'model': 'gpt-4o',
              'choices': [
                {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
              ],
            })}\n\n';
        return http.StreamedResponse(
          () async* {
            yield utf8.encode(chunk);
            // Held open until the test cancels — the tool must abort here.
            await source.token.onCancel;
            yield utf8.encode(done);
          }(),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: '[REDACTED:Sensitive-Value]',
        httpClient: client,
      );
      final tool = inspectImageTool(env, config);
      final future = tool.execute(
        {'path': '/work/shot.png'},
        source.token,
        null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      source.cancel();
      Object outcome;
      try {
        final result = await future;
        outcome = result.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join();
      } on Object catch (error) {
        outcome = error;
      }
      expect(
        outcome,
        isA<CancelledException>(),
        reason: 'a user cancel must abort a hung vision stream mid-flight',
      );
    });

    test('reports the vision call usage via onUsage (/cost parity)', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final client = http_testing.MockClient.streaming((request, body) async {
        final payload =
            'data: ${jsonEncode({
              'id': 'c',
              'object': 'chat.completion.chunk',
              'created': 1,
              'model': 'gpt-4o',
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant', 'content': 'A small red pixel.'},
                  'finish_reason': null,
                },
              ],
            })}\n\n';
        final done =
            'data: ${jsonEncode({
              'id': 'c',
              'object': 'chat.completion.chunk',
              'created': 1,
              'model': 'gpt-4o',
              'choices': [
                {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
              ],
              'usage': {'prompt_tokens': 1200, 'completion_tokens': 42, 'total_tokens': 1242},
            })}\n\n';
        return http.StreamedResponse(
          Stream.fromIterable([utf8.encode(payload), utf8.encode(done)]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final config = InspectImageConfig(
        modelId: 'gpt-4o',
        apiKey: '[REDACTED:Sensitive-Value]',
        httpClient: client,
      );
      final usages = <Usage>[];
      final tool = inspectImageTool(env, config, onUsage: usages.add);
      await tool.execute({'path': '/work/shot.png'}, null, null);
      expect(usages, hasLength(1));
      expect(usages.first.totalTokens, 1242);
    });
  });
}
