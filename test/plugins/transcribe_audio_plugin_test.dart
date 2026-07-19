import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

Uint8List _fakeWav() => Uint8List.fromList(utf8.encode('RIFF....WAVE fake'));

http.Client _fakeTranscribeClient(String transcript) {
  return http_testing.MockClient.streaming((request, bodyStream) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'text': transcript}))),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  group('TranscribeAudioPlugin', () {
    late MemoryExecutionEnv env;
    late _FakePluginIO pluginIO;

    setUp(() {
      env = MemoryExecutionEnv();
      pluginIO = _FakePluginIO();
    });

    PluginContext context(Map<String, dynamic> config) {
      return PluginContext(env: env, io: pluginIO, config: config);
    }

    test('registers transcribe_audio tool when configured', () {
      final plugin = TranscribeAudioPlugin(
        httpClient: _fakeTranscribeClient('ok'),
      );
      final ctx = context({'apiKey': 'transcribe-key'});
      plugin.register(ctx);

      expect(ctx.tools, hasLength(1));
      expect(ctx.tools.first.name, 'transcribe_audio');
    });

    test('skips registration when apiKey is missing', () {
      const plugin = TranscribeAudioPlugin();
      final ctx = context({'model': 'whisper-1'});
      plugin.register(ctx);

      expect(ctx.tools, isEmpty);
    });

    test('registered tool can transcribe audio', () async {
      await env.writeBinaryFile('/work/clip.wav', _fakeWav());
      final plugin = TranscribeAudioPlugin(
        httpClient: _fakeTranscribeClient('a transcribed sentence'),
      );
      final ctx = context({
        'model': 'whisper-1',
        'apiKey': 'transcribe-key',
        'language': 'en',
      });
      plugin.register(ctx);

      final tool = ctx.tools.first;
      final result = await tool.execute({'path': '/work/clip.wav'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'a transcribed sentence');
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
