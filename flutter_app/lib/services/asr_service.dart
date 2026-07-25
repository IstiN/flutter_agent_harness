// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

export 'package:fa/services/asr_service_stub.dart'
    if (dart.library.io) 'package:fa/services/asr_service_io.dart';

/// One finished microphone recording: the host-side file [path] (a
/// temporary `.m4a` the caller reads via [AsrApi.readRecording]), the
/// captured [durationMs], and the [sampleRate] (Hz) it was recorded at.
typedef AsrRecording = ({String path, int durationMs, int sampleRate});

/// Microphone capture (AVAudioRecorder on macOS/iOS via the `fah/mic`
/// method channel) for the chat composer's voice input, the agent's
/// `mic_record` tool, and the `jsr.fa.asr` JS bridge.
///
/// Use [createAsrService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/mic` method channel on IO platforms, a
/// never-available stub on web. Tests inject fakes.
abstract interface class AsrApi {
  /// Whether this platform can record from the microphone at all.
  Future<bool> get isAvailable;

  /// Asks the OS for microphone access (prompts once, then returns the
  /// stored decision). True when recording may start.
  Future<bool> requestAccess();

  /// Starts capturing into a fresh temporary file. The native side caps a
  /// single take at [asrMaxRecordSeconds].
  Future<void> startRecording();

  /// Stops the in-flight recording and returns its file + duration.
  Future<AsrRecording> stopRecording();

  /// Reads the bytes of a recording (or any audio file) at a host [path].
  Future<Uint8List> readRecording(String path);
}

/// Longest single recording in seconds — enforced natively (the recorder
/// auto-stops) and by the argument clamp [asrRecordSeconds].
const asrMaxRecordSeconds = 120;

/// Validates a `seconds` argument (1–[asrMaxRecordSeconds], default
/// [defaultSeconds]) shared by the agent tool and the JS bridge.
int asrRecordSeconds(num? value, {int defaultSeconds = 10}) {
  final seconds = (value ?? defaultSeconds).round();
  if (seconds < 1) return 1;
  if (seconds > asrMaxRecordSeconds) return asrMaxRecordSeconds;
  return seconds;
}

/// Speech-to-text for a recorded audio payload. Kept minimal and injectable
/// so tests never touch the network; the production implementation is
/// [WhisperTranscriber].
abstract interface class AsrTranscriber {
  /// Turns the audio [bytes] (named [filename] — endpoints key off the
  /// extension) into a transcript.
  Future<String> transcribe({
    required Uint8List bytes,
    required String filename,
  });
}

/// The user-facing explanation when no ASR-capable endpoint is configured
/// (shared by the chat composer and the JS bridge).
const asrNoEndpointMessage =
    'No ASR-capable endpoint is configured — connect an OpenAI-compatible '
    'provider (one that serves Whisper /audio/transcriptions) in the Fa '
    'settings, then try again.';

/// The transcription endpoint for the active provider when it is an
/// OpenAI-compatible one (the only provider kind that can serve Whisper
/// `/audio/transcriptions`); `null` — meaning "no ASR-capable endpoint
/// configured", surface [asrNoEndpointMessage] — for the on-device backends,
/// Anthropic/Google, or a missing API key.
TranscribeAudioConfig? asrTranscribeConfig({
  required String providerKind,
  required String baseUrl,
  required String apiKey,
}) {
  if (providerKind != 'openai-completions' || apiKey.isEmpty) return null;
  return TranscribeAudioConfig(
    apiKey: apiKey,
    baseUrl: baseUrl.isEmpty ? null : baseUrl,
  );
}

/// The [AsrTranscriber] riding the active provider's endpoint (see
/// [asrTranscribeConfig]); `null` when no ASR-capable endpoint is
/// configured. [httpClient] is injectable for tests.
AsrTranscriber? whisperTranscriberFor({
  required String providerKind,
  required String baseUrl,
  required String apiKey,
  http.Client? httpClient,
}) {
  final config = asrTranscribeConfig(
    providerKind: providerKind,
    baseUrl: baseUrl,
    apiKey: apiKey,
  );
  if (config == null) return null;
  return WhisperTranscriber(config: config, httpClient: httpClient);
}

/// [AsrTranscriber] over a Whisper-compatible `/audio/transcriptions`
/// endpoint (OpenAI, Groq, or a local whisper.cpp server) — the same wire
/// shape as the harness's `transcribe_audio` tool.
final class WhisperTranscriber implements AsrTranscriber {
  /// Creates a transcriber for [config]; [httpClient] is injectable for
  /// tests.
  const WhisperTranscriber({required this.config, this.httpClient});

  /// Endpoint configuration (key, base URL, model id).
  final TranscribeAudioConfig config;

  /// Optional HTTP client override (tests).
  final http.Client? httpClient;

  @override
  Future<String> transcribe({
    required Uint8List bytes,
    required String filename,
  }) async {
    final baseUrl = config.baseUrl ?? 'https://api.openai.com/v1';
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/audio/transcriptions'),
          )
          ..headers['authorization'] = 'Bearer ${config.apiKey}'
          ..fields['model'] = config.modelId
          ..fields['response_format'] = 'json'
          ..files.add(
            // The file part's content type stays application/octet-stream;
            // the endpoints key off the filename extension instead.
            http.MultipartFile.fromBytes('file', bytes, filename: filename),
          );
    final language = config.language;
    if (language != null && language.isNotEmpty) {
      request.fields['language'] = language;
    }

    final client = httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request));
    } finally {
      if (httpClient == null) client.close();
    }

    if (response.statusCode != 200) {
      throw StateError(
        'Transcription failed (HTTP ${response.statusCode}): '
        '${response.body.trim()}',
      );
    }

    // `response_format=json` answers `{"text": "..."}`; whisper.cpp variants
    // may answer with the bare transcript, so fall back to the raw body.
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['text'] is String) {
        return (decoded['text'] as String).trim();
      }
    } on FormatException {
      // Not JSON: fall through to the raw body.
    }
    return response.body.trim();
  }
}
