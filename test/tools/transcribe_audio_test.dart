import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

Uint8List _fakeWav() =>
    Uint8List.fromList(utf8.encode('RIFF....WAVEfmt fake-audio-bytes'));

/// Captures the outgoing request and answers [statusCode] with [body].
http.Client _captureClient(
  void Function(http.BaseRequest request, String body) onRequest, {
  int statusCode = 200,
  Object? body = const {'text': 'hello world'},
}) {
  return http_testing.MockClient.streaming((request, bodyStream) async {
    final bodyText = await bodyStream.bytesToString();
    onRequest(request, bodyText);
    final payload = body is String ? body : jsonEncode(body);
    return http.StreamedResponse(
      Stream.value(utf8.encode(payload)),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  group('transcribeAudioTool', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv();
    });

    test('sends a multipart request and returns the transcript', () async {
      await env.writeBinaryFile('/work/clip.wav', _fakeWav());
      http.BaseRequest? seenRequest;
      String? seenBody;
      final config = TranscribeAudioConfig(
        apiKey: 'transcribe-key',
        httpClient: _captureClient((request, body) {
          seenRequest = request;
          seenBody = body;
        }),
      );
      final tool = transcribeAudioTool(env, config);
      final result = await tool.execute({'path': '/work/clip.wav'}, null, null);

      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'hello world');

      final request = seenRequest!;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://api.openai.com/v1/audio/transcriptions',
      );
      expect(request.headers['authorization'], 'Bearer transcribe-key');
      expect(
        request.headers['content-type'],
        contains('multipart/form-data; boundary='),
      );

      final body = seenBody!;
      expect(body, contains('name="model"'));
      expect(body, contains('whisper-1'));
      expect(body, contains('name="response_format"'));
      expect(body, contains('name="file"; filename="clip.wav"'));
      expect(body, contains('fake-audio-bytes'));
      expect(body, isNot(contains('name="language"')));
    });

    test('honours baseUrl, model id, and language overrides', () async {
      await env.writeBinaryFile('/work/clip.mp3', _fakeWav());
      final bodies = <String>[];
      http.BaseRequest? seenRequest;
      final config = TranscribeAudioConfig(
        modelId: 'whisper-large-v3',
        apiKey: 'groq-key',
        baseUrl: 'https://api.groq.com/openai/v1',
        language: 'en',
        httpClient: _captureClient((request, body) {
          seenRequest = request;
          bodies.add(body);
        }),
      );
      final tool = transcribeAudioTool(env, config);

      // Configured default language.
      await tool.execute({'path': '/work/clip.mp3'}, null, null);
      // Per-call override wins over the configured default.
      await tool.execute(
        {'path': '/work/clip.mp3', 'language': 'de'},
        null,
        null,
      );

      expect(
        seenRequest!.url.toString(),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      expect(bodies[0], contains('whisper-large-v3'));
      expect(bodies[0], contains('name="language"'));
      expect(bodies[0], contains('\r\nen\r\n'));
      expect(bodies[1], contains('\r\nde\r\n'));
    });

    test('falls back to the raw body when the response is not JSON', () async {
      await env.writeBinaryFile('/work/clip.ogg', _fakeWav());
      final config = TranscribeAudioConfig(
        apiKey: 'key',
        httpClient: _captureClient((request, body) {}, body: 'raw transcript'),
      );
      final tool = transcribeAudioTool(env, config);
      final result = await tool.execute({'path': '/work/clip.ogg'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, 'raw transcript');
    });

    test('refuses files over 25MB without calling the endpoint', () async {
      await env.writeBinaryFile(
        '/work/huge.flac',
        Uint8List(maxTranscribeAudioBytes + 1),
      );
      var called = false;
      final config = TranscribeAudioConfig(
        apiKey: 'key',
        httpClient: http_testing.MockClient.streaming((request, body) async {
          called = true;
          return http.StreamedResponse(const Stream.empty(), 200);
        }),
      );
      final tool = transcribeAudioTool(env, config);
      await expectLater(
        tool.execute({'path': '/work/huge.flac'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('25MB'),
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('throws with status and body on http errors', () async {
      await env.writeBinaryFile('/work/clip.wav', _fakeWav());
      final config = TranscribeAudioConfig(
        apiKey: 'bad-key',
        httpClient: _captureClient(
          (request, body) {},
          statusCode: 401,
          body: const {
            'error': {'message': 'Invalid API key'},
          },
        ),
      );
      final tool = transcribeAudioTool(env, config);
      await expectLater(
        tool.execute({'path': '/work/clip.wav'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP 401'), contains('Invalid API key')),
          ),
        ),
      );
    });

    test('throws for an unsupported audio extension', () async {
      await env.writeFile('/work/notes.txt', 'just text');
      final config = TranscribeAudioConfig(apiKey: 'key');
      final tool = transcribeAudioTool(env, config);
      await expectLater(
        tool.execute({'path': '/work/notes.txt'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported audio format'),
          ),
        ),
      );
    });

    test('throws when the file is missing', () async {
      final config = TranscribeAudioConfig(apiKey: 'key');
      final tool = transcribeAudioTool(env, config);
      await expectLater(
        tool.execute({'path': '/work/missing.mp3'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('defaults modelId to whisper-1', () {
      const config = TranscribeAudioConfig(apiKey: 'key');
      expect(config.modelId, 'whisper-1');
    });

    test('accepts every documented extension', () async {
      var calls = 0;
      final config = TranscribeAudioConfig(
        apiKey: 'key',
        httpClient: _captureClient((request, body) => calls++),
      );
      final tool = transcribeAudioTool(env, config);
      for (final ext in supportedAudioExtensions) {
        await env.writeBinaryFile('/work/clip.$ext', _fakeWav());
        await tool.execute({'path': '/work/clip.$ext'}, null, null);
      }
      expect(calls, supportedAudioExtensions.length);
    });
  });
}
