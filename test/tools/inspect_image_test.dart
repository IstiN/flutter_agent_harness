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
  });
}
