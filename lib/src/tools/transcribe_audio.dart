/// Audio transcription tool (`transcribe_audio`) for [AgentCli].
///
/// Shaped after [inspect_image]: a Whisper-compatible `/audio/transcriptions`
/// endpoint (OpenAI, Groq, OpenRouter, or a local whisper.cpp server) turns a
/// local audio file into text. Keeping the audio payload out of the main chat
/// context means the primary model does not need audio support — only the
/// transcript enters the conversation, so the tool works for every provider,
/// including Anthropic. Pure-Dart `package:http` multipart upload; web-safe.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../env/execution_env.dart';
import '../types.dart';

/// Largest accepted audio payload: 25MB, matching OpenAI's upload cap for the
/// transcription endpoint.
const maxTranscribeAudioBytes = 25 * 1024 * 1024;

/// Audio file extensions accepted by the tool (Whisper-compatible formats).
const supportedAudioExtensions = {'wav', 'mp3', 'm4a', 'ogg', 'webm', 'flac'};

/// Configuration for the [transcribeAudioTool] transcription endpoint.
final class TranscribeAudioConfig {
  /// Creates a configuration.
  const TranscribeAudioConfig({
    this.modelId = 'whisper-1',
    required this.apiKey,
    this.baseUrl,
    this.language,
    this.httpClient,
  });

  /// Transcription model id, e.g. `whisper-1` (OpenAI) or `whisper-large-v3`
  /// (Groq). Defaults to `whisper-1`.
  final String modelId;

  /// API key for the transcription provider.
  final String apiKey;

  /// Optional base URL of the Whisper-compatible endpoint;
  /// `/audio/transcriptions` is appended. When omitted, OpenAI's default is
  /// used (https://api.openai.com/v1).
  final String? baseUrl;

  /// Optional ISO-639-1 language hint sent as the `language` form field.
  final String? language;

  /// Optional HTTP client for testing.
  final http.Client? httpClient;
}

/// Sends the audio to the transcription endpoint and returns the transcript.
Future<String> _transcribe(
  TranscribeAudioConfig config,
  Uint8List bytes,
  String filename,
  String? language,
) async {
  final baseUrl = config.baseUrl ?? 'https://api.openai.com/v1';
  final request =
      http.MultipartRequest('POST', Uri.parse('$baseUrl/audio/transcriptions'))
        ..headers['authorization'] = 'Bearer ${config.apiKey}'
        ..fields['model'] = config.modelId
        ..fields['response_format'] = 'json'
        ..files.add(
          // The file part's content type stays application/octet-stream; the
          // endpoints key off the filename extension instead.
          http.MultipartFile.fromBytes('file', bytes, filename: filename),
        );
  final hint = language ?? config.language;
  if (hint != null && hint.isNotEmpty) {
    request.fields['language'] = hint;
  }

  final client = config.httpClient ?? http.Client();
  final http.Response response;
  try {
    response = await http.Response.fromStream(await client.send(request));
  } finally {
    if (config.httpClient == null) {
      client.close();
    }
  }

  if (response.statusCode != 200) {
    throw StateError(
      'Transcription failed (HTTP ${response.statusCode}): '
      '${response.body.trim()}',
    );
  }

  // `response_format=json` answers `{"text": "..."}`; whisper.cpp variants may
  // answer with the bare transcript, so fall back to the raw body.
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

/// Creates the `transcribe_audio` tool.
///
/// Parameters:
/// - `path` (string, required): path to the audio file.
/// - `language` (string, optional): ISO-639-1 language hint, overriding the
///   configured default.
AgentTool transcribeAudioTool(ExecutionEnv env, TranscribeAudioConfig config) {
  return AgentTool(
    name: 'transcribe_audio',
    label: 'transcribe_audio',
    tier: ApprovalTier.read,
    description:
        'Transcribe a local audio file to text using a Whisper-compatible '
        'transcription endpoint. Returns the transcript; the audio itself '
        'does not enter the chat context. Supported formats: WAV, MP3, M4A, '
        'OGG, WebM, FLAC. Maximum file size: 25MB.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': 'Path to the audio file (relative or absolute)',
        },
        'language': {
          'type': 'string',
          'description':
              'Optional ISO-639-1 language hint (e.g. "en", "de"); overrides '
              'the configured default',
        },
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final path = arguments['path'] as String;
      final language = (arguments['language'] as String?) ?? config.language;

      final filename = path.split(RegExp(r'[/\\]')).last;
      final dot = filename.lastIndexOf('.');
      final extension = dot >= 0
          ? filename.substring(dot + 1).toLowerCase()
          : '';
      if (!supportedAudioExtensions.contains(extension)) {
        throw StateError(
          'Unsupported audio format: $filename (supported: '
          '${(supportedAudioExtensions.toList()..sort()).join(', ')})',
        );
      }

      final read = await env.readBinaryFile(path);
      if (read.isErr) {
        throw StateError('${read.errorOrNull}');
      }
      final bytes = read.valueOrNull!;
      cancelToken?.throwIfCancelled();

      if (bytes.length > maxTranscribeAudioBytes) {
        throw StateError(
          'Audio file too large: ${bytes.length} bytes exceeds the 25MB '
          'transcription limit',
        );
      }

      final transcript = await _transcribe(config, bytes, filename, language);
      return ToolExecutionResult(content: [TextContent(text: transcript)]);
    },
  );
}
