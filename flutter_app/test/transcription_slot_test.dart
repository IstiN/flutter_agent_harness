// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/services/asr_service.dart';
import 'package:fa/services/asr_tool.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Serves a fixed HTTP response and captures the requests — the Whisper
/// endpoint tests never touch the network.
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

MediaGateway _gateway(
  MemoryExecutionEnv env,
  MediaModelsStore store, {
  String providerKind = 'openai-completions',
  String baseUrl = 'https://api.test/v1',
  String apiKey = 'sk-main',
  MediaKeyResolver? resolveKey,
}) => MediaGateway(
  env: env,
  fallback: () => MediaFallback(
    providerKind: providerKind,
    baseUrl: baseUrl,
    modelId: 'gpt-5',
    apiKey: apiKey,
  ),
  store: store,
  resolveKey: resolveKey,
);

const _override = MediaSlotOverride(
  providerKind: 'openai-completions',
  baseUrl: 'https://asr.example.com/v1',
  modelId: 'whisper-large-v3',
  apiKeyName: 'ASR_KEY',
);

/// Answers every slot's named key. A slot override NEVER uses the main
/// connection key — only its own named key.
MediaKeyResolver _slotKeyResolver(String value) =>
    (name) async => name.endsWith('_KEY') ? value : null;

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('whisperTranscriberForGateway (transcription slot resolution)', () {
    test(
      'no override falls back to the active provider with whisper-1',
      () async {
        final env = MemoryExecutionEnv();
        final transcriber = await whisperTranscriberForGateway(
          _gateway(env, MediaModelsStore.inMemory()),
        );

        expect(transcriber, isA<WhisperTranscriber>());
        final config = (transcriber! as WhisperTranscriber).config;
        expect(config.baseUrl, 'https://api.test/v1');
        expect(config.modelId, 'whisper-1');
        expect(config.apiKey, 'sk-main');
      },
    );

    test('a configured override wins and uses its own named key', () async {
      final env = MemoryExecutionEnv();
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.transcription, _override);

      final transcriber = await whisperTranscriberForGateway(
        _gateway(env, store, resolveKey: _slotKeyResolver('sk-slot')),
      );

      final config = (transcriber! as WhisperTranscriber).config;
      expect(config.baseUrl, 'https://asr.example.com/v1');
      expect(config.modelId, 'whisper-large-v3');
      expect(config.apiKey, 'sk-slot');
    });

    test('an override without a resolvable named key is unusable', () async {
      final env = MemoryExecutionEnv();
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.transcription, _override);

      // No key named ASR_KEY anywhere: the endpoint is not usable and
      // the main connection key is never substituted.
      final transcriber = await whisperTranscriberForGateway(
        _gateway(env, store),
      );
      expect(transcriber, isNull);
    });

    test('an override apiKeyName resolves through the key resolver', () async {
      final env = MemoryExecutionEnv();
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.transcription,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://asr.example.com/v1',
          modelId: 'whisper-large-v3',
          apiKeyName: 'ASR_KEY',
        ),
      );

      final transcriber = await whisperTranscriberForGateway(
        _gateway(
          env,
          store,
          resolveKey: (name) async => name == 'ASR_KEY' ? 'sk-asr' : null,
        ),
      );

      expect((transcriber! as WhisperTranscriber).config.apiKey, 'sk-asr');
    });

    test('null when the fallback is not OpenAI-compatible', () async {
      final env = MemoryExecutionEnv();
      final transcriber = await whisperTranscriberForGateway(
        _gateway(env, MediaModelsStore.inMemory(), providerKind: 'anthropic'),
      );
      expect(transcriber, isNull);
    });

    test('null when the override key does not resolve', () async {
      final env = MemoryExecutionEnv();
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.transcription,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://asr.example.com/v1',
          modelId: 'whisper-large-v3',
          apiKeyName: 'MISSING_KEY',
        ),
      );

      final transcriber = await whisperTranscriberForGateway(
        _gateway(env, store, resolveKey: (name) async => null),
      );
      expect(transcriber, isNull);
    });
  });

  group('transcriptionTool', () {
    test('keeps the harness tool surface (name, read tier)', () {
      final tool = transcriptionTool(MemoryExecutionEnv(), () async => null);
      expect(tool.name, transcribeAudioToolName);
      expect(tool.name, 'transcribe_audio');
      expect(tool.tier, ApprovalTier.read);
    });

    test('transcribes through the resolved slot endpoint', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile(
        'recordings/take.m4a',
        Uint8List.fromList([1, 2, 3]),
      );
      final store = MediaModelsStore.inMemory();
      await store.setOverride(MediaSlot.transcription, _override);
      final client = _FakeHttpClient(200, '{"text": " slot transcript "}');
      final tool = transcriptionTool(
        env,
        () => whisperTranscriberForGateway(
          _gateway(env, store, resolveKey: _slotKeyResolver('sk-slot')),
          httpClient: client,
        ),
      );

      final result = await tool.execute(
        const {'path': 'recordings/take.m4a'},
        null,
        null,
      );

      expect(_textOf(result), 'slot transcript');
      final request = client.requests.single;
      expect(
        request.url.toString(),
        'https://asr.example.com/v1/audio/transcriptions',
      );
    });

    test(
      'answers with the no-endpoint guidance when nothing resolves',
      () async {
        final env = MemoryExecutionEnv();
        await env.writeBinaryFile('take.m4a', Uint8List.fromList([1]));
        final tool = transcriptionTool(env, () async => null);

        final result = await tool.execute(
          const {'path': 'take.m4a'},
          null,
          null,
        );

        final text = _textOf(result);
        expect(text, contains('No ASR-capable endpoint'));
        expect(text, contains('transcription'));
        expect(text, contains('media_models.json'));
      },
    );

    test('rejects unsupported formats like the harness tool', () async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile('notes.txt', Uint8List.fromList([1]));
      final tool = transcriptionTool(env, () async => null);

      expect(
        () => tool.execute(const {'path': 'notes.txt'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported audio format'),
          ),
        ),
      );
    });
  });
}
