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
  group('InspectImagePlugin', () {
    late MemoryExecutionEnv env;
    late _FakePluginIO pluginIO;

    setUp(() {
      env = MemoryExecutionEnv();
      pluginIO = _FakePluginIO();
    });

    PluginContext context(Map<String, dynamic> config) {
      return PluginContext(env: env, io: pluginIO, config: config);
    }

    test('registers inspect_image tool when configured', () {
      final plugin = InspectImagePlugin(httpClient: _fakeVisionClient('ok'));
      final ctx = context({
        'model': 'gpt-4o',
        'apiKey': 'vision-key',
        'maxTokens': 1024,
      });
      plugin.register(ctx);

      expect(ctx.tools, hasLength(1));
      expect(ctx.tools.first.name, 'inspect_image');
    });

    test('skips registration when model is missing', () {
      final plugin = const InspectImagePlugin();
      final ctx = context({'apiKey': 'vision-key'});
      plugin.register(ctx);

      expect(ctx.tools, isEmpty);
    });

    test('skips registration when apiKey is missing', () {
      final plugin = const InspectImagePlugin();
      final ctx = context({'model': 'gpt-4o'});
      plugin.register(ctx);

      expect(ctx.tools, isEmpty);
    });

    test('registered tool can describe an image', () async {
      await env.writeBinaryFile('/work/shot.png', _makePng());
      final plugin = InspectImagePlugin(
        httpClient: _fakeVisionClient('A small red pixel.'),
      );
      final ctx = context({'model': 'gpt-4o', 'apiKey': 'vision-key'});
      plugin.register(ctx);

      final tool = ctx.tools.first;
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
  });
}

final class _FakePluginIO implements PluginIO {
  final buffer = StringBuffer();

  @override
  void write(String text) => buffer.write(text);

  @override
  void writeln(String text) => buffer.writeln(text);
}
