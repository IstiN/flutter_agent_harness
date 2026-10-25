// Issue #1886: `.fah/packages.yaml` transcribe_audio section parses the new
// timestamped-transcription knobs and fails loudly on unknown keys (same
// strictness as MediaSlotModelConfig.fromYaml).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

Uint8List _fakeWav() => Uint8List.fromList(utf8.encode('RIFF....WAVE fake'));

class _FakePluginIO implements PluginIO {
  @override
  void write(String text) {}
  @override
  void writeln(String text) {}
}

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv();
  });

  PluginContext context(Map<String, dynamic> config) =>
      PluginContext(env: env, io: _FakePluginIO(), config: config);

  group('TranscribeAudioPlugin yaml knobs', () {
    test('valid full section registers the tool', () {
      const plugin = TranscribeAudioPlugin();
      final ctx = context({
        'apiKey': 'k',
        'model': 'whisper-large-v3',
        'responseFormat': 'verbose',
        'granularities': ['segment', 'word'],
        'require': 'word',
        'prompt': 'artist names',
        'output': 'auto',
        'maxInlineBytes': 4096,
        'providerKind': 'groq',
      });
      plugin.register(ctx);
      expect(ctx.tools, hasLength(1));
    });

    test('unknown keys fail loudly naming the offenders', () {
      const plugin = TranscribeAudioPlugin();
      expect(
        () => plugin.register(context({'apiKey': 'k', 'respnseFormat': 'v'})),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('respnseFormat'), contains('transcribe_audio')),
          ),
        ),
      );
    });

    test('invalid enum values fail loudly listing allowed values', () {
      const plugin = TranscribeAudioPlugin();
      expect(
        () => plugin.register(
          context({'apiKey': 'k', 'responseFormat': 'super'}),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('responseFormat'), contains('verbose')),
          ),
        ),
      );
      expect(
        () => plugin.register(
          context({'apiKey': 'k', 'maxInlineBytes': '20000'}),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('maxInlineBytes'), contains('positive integer')),
          ),
        ),
      );
      expect(
        () => plugin.register(
          context({
            'apiKey': 'k',
            'granularities': ['syllable'],
          }),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => plugin.register(context({'apiKey': 'k', 'require': 'always'})),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => plugin.register(context({'apiKey': 'k', 'output': 'maybe'})),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => plugin.register(
          context({'apiKey': 'k', 'providerKind': 'mystery'}),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('configured knobs reach the registered tool end-to-end', () async {
      await env.writeBinaryFile('/work/clip.wav', _fakeWav());
      final bodies = <String>[];
      final client = http_testing.MockClient.streaming((
        request,
        bodyStream,
      ) async {
        bodies.add(await bodyStream.bytesToString());
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'text': 'hello',
                'segments': [
                  {'id': 0, 'start': 0.0, 'end': 1.0, 'text': 'hello'},
                ],
              }),
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final plugin = TranscribeAudioPlugin(httpClient: client);
      final ctx = context({
        'apiKey': 'k',
        'responseFormat': 'verbose',
        'granularities': ['segment'],
        'prompt': 'jargon',
      });
      plugin.register(ctx);
      final result = await ctx.tools.single.execute(
        {'path': '/work/clip.wav'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      final document = jsonDecode(text) as Map<String, dynamic>;
      expect(document['schemaVersion'], 1);
      expect(bodies.single, contains('verbose_json'));
      expect(bodies.single, contains('jargon'));
    });
  });
}
