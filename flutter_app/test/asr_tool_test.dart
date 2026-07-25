// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/asr_service.dart';
import 'package:fa/services/asr_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Configurable fake [AsrApi] — the host-side tests never touch the real
/// method channel.
final class FakeAsrApi implements AsrApi {
  bool available = true;
  bool granted = true;
  int requestAccessCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  final readPaths = <String>[];
  Uint8List recordingBytes = Uint8List.fromList([1, 2, 3, 4]);

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<AsrRecording> stopRecording() async {
    stopCalls++;
    return (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    readPaths.add(path);
    return recordingBytes;
  }
}

/// Serves a fixed HTTP response — the Whisper endpoint tests never touch
/// the network.
final class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this.statusCode, this.body);

  final int statusCode;
  final String body;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return Future.value(
      http.StreamedResponse(Stream.value(utf8.encode(body)), statusCode),
    );
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('micRecordTool', () {
    test('is a write-tier tool (recording is privacy-sensitive)', () {
      final tool = micRecordTool(FakeAsrApi(), MemoryExecutionEnv());
      expect(tool.name, micRecordToolName);
      expect(tool.tier, ApprovalTier.write);
    });

    test(
      'records, waits, stops, and stages the take into the sandbox',
      () async {
        final asr = FakeAsrApi();
        final env = MemoryExecutionEnv();
        final waited = <int>[];
        final tool = micRecordTool(asr, env, wait: (s) async => waited.add(s));

        final result = await tool.execute(const {'seconds': 3}, null, null);

        expect(asr.requestAccessCalls, 1);
        expect(asr.startCalls, 1);
        expect(asr.stopCalls, 1);
        expect(waited, [3]);
        expect(asr.readPaths, ['/tmp/fah-mic-test.m4a']);
        final text = _textOf(result);
        expect(text, contains('Recorded 3 s of audio to recordings/mic-'));
        expect(text, contains('.m4a'));
        expect(text, contains('44100 Hz'));
        expect(text, contains('transcribe_audio'));
        // The take is readable inside the sandbox (pairs with
        // transcribe_audio and the file tools).
        final path = RegExp(
          r'recordings/mic-\d+\.m4a',
        ).firstMatch(text)!.group(0)!;
        final stored = await env.readBinaryFile(path);
        expect(stored.valueOrNull, asr.recordingBytes);
      },
    );

    test('clamps the duration to 1..120 s', () async {
      final asr = FakeAsrApi();
      final waited = <int>[];
      final tool = micRecordTool(
        asr,
        MemoryExecutionEnv(),
        wait: (s) async => waited.add(s),
      );

      await tool.execute(const {'seconds': 999}, null, null);
      await tool.execute(const {'seconds': 0}, null, null);
      await tool.execute(const {}, null, null); // default

      expect(waited, [asrMaxRecordSeconds, 1, 10]);
    });

    test('denied OS access answers with where to enable it and never '
        'records', () async {
      final asr = FakeAsrApi()..granted = false;
      final tool = micRecordTool(asr, MemoryExecutionEnv());

      final result = await tool.execute(const {}, null, null);

      final text = _textOf(result);
      expect(text, contains('Microphone access was denied'));
      expect(text, contains('Privacy & Security → Microphone'));
      expect(asr.startCalls, 0);
      expect(asr.stopCalls, 0);
    });

    test('unsupported platform answers with a clean note', () async {
      final asr = FakeAsrApi()..available = false;
      final tool = micRecordTool(asr, MemoryExecutionEnv());

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(asr.startCalls, 0);
    });
  });

  group('asrTranscribeConfig / whisperTranscriberFor', () {
    test('resolves only for an OpenAI-compatible provider with a key', () {
      expect(
        asrTranscribeConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
        ),
        isNotNull,
      );
      // Empty base URL falls back to the OpenAI default (null baseUrl).
      final fallback = asrTranscribeConfig(
        providerKind: 'openai-completions',
        baseUrl: '',
        apiKey: 'sk-test',
      );
      expect(fallback, isNotNull);
      expect(fallback!.baseUrl, isNull);

      for (final kind in ['anthropic', 'google', 'webllm', 'gemma']) {
        expect(
          asrTranscribeConfig(
            providerKind: kind,
            baseUrl: 'https://example.com',
            apiKey: 'sk-test',
          ),
          isNull,
          reason: kind,
        );
      }
      expect(
        asrTranscribeConfig(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: '',
        ),
        isNull,
      );
    });

    test('whisperTranscriberFor mirrors the config gate', () {
      expect(
        whisperTranscriberFor(
          providerKind: 'openai-completions',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
        ),
        isA<WhisperTranscriber>(),
      );
      expect(
        whisperTranscriberFor(providerKind: 'gemma', baseUrl: '', apiKey: ''),
        isNull,
      );
    });

    test('the no-endpoint guidance tells the user what to configure', () {
      expect(asrNoEndpointMessage, contains('OpenAI-compatible'));
      expect(asrNoEndpointMessage, contains('settings'));
    });
  });

  group('WhisperTranscriber', () {
    WhisperTranscriber transcriber(http.Client client) => WhisperTranscriber(
      config: TranscribeAudioConfig(
        apiKey: 'sk-test',
        baseUrl: 'https://asr.example.com/v1',
        httpClient: client,
      ),
      httpClient: client,
    );

    test(
      'posts the audio to /audio/transcriptions and parses {text}',
      () async {
        final client = _FakeHttpClient(200, '{"text": " hello world "}');
        final text = await transcriber(
          client,
        ).transcribe(bytes: Uint8List.fromList([1, 2, 3]), filename: 'mic.m4a');

        expect(text, 'hello world');
        final request = client.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://asr.example.com/v1/audio/transcriptions',
        );
        expect(request.headers['authorization'], 'Bearer sk-test');
      },
    );

    test('falls back to the raw body for non-JSON answers', () async {
      final client = _FakeHttpClient(200, 'bare transcript');
      final text = await transcriber(
        client,
      ).transcribe(bytes: Uint8List.fromList([1]), filename: 'mic.m4a');
      expect(text, 'bare transcript');
    });

    test('endpoint failures surface the HTTP status and body', () async {
      final client = _FakeHttpClient(401, '{"error": "bad key"}');
      expect(
        () => transcriber(
          client,
        ).transcribe(bytes: Uint8List.fromList([1]), filename: 'mic.m4a'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('HTTP 401'), contains('bad key')),
          ),
        ),
      );
    });
  });
}
