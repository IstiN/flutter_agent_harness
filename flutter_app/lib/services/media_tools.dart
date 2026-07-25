// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/services/media_models_store.dart';

/// Directory (relative to the env's working directory) generated media
/// files are saved into so the agent (and JS apps) can reference them with
/// the regular file tools.
const generatedMediaDir = 'generated';

/// One generated media file staged in the sandbox: the env-relative [path],
/// its [bytes], and a human/LLM-facing [detail] (image size, voice, source
/// URL, …) for the result text.
final class GeneratedMediaFile {
  /// Creates a result.
  const GeneratedMediaFile({
    required this.path,
    required this.bytes,
    required this.detail,
  });

  /// Env-relative sandbox path (under [generatedMediaDir]).
  final String path;

  /// The file content.
  final Uint8List bytes;

  /// Extra detail for the result text (e.g. `1024x1024`, `voice "alloy"`).
  final String detail;

  /// JSON form for the `jsr.fa.media.*` bridge (bytes stay host-side — the
  /// app reads the file from the sandbox).
  Map<String, Object?> toBridgeJson() => {
    'path': path,
    'bytes': bytes.length,
    'detail': detail,
  };
}

/// Media generation against the per-modality endpoints configured in
/// [MediaModelsStore] (falling back to the app's main connection).
///
/// Shared by the agent's `generate_image` / `speak` / `generate_music`
/// tools and the `jsr.fa.media.*` JS bridge so both resolve endpoints
/// identically. The store is (re)loaded per call when none was injected, so
/// edits to `media_models.json` take effect without a reconnect. All
/// failures surface as [StateError] with an actionable, user-readable
/// message (never a bare exception).
final class MediaGateway {
  /// Creates a gateway over [env]. [fallback] supplies the main
  /// connection's endpoint details (called per request, so provider
  /// switches are picked up). [httpClient] is injectable for tests.
  const MediaGateway({
    required this.env,
    required MediaFallback Function() fallback,
    MediaModelsStore? store,
    MediaKeyResolver? resolveKey,
    http.Client? httpClient,
  }) : _fallback = fallback,
       _store = store,
       _resolveKey = resolveKey,
       _httpClient = httpClient;

  /// The sandbox filesystem generated files land in.
  final ExecutionEnv env;

  final MediaFallback Function() _fallback;
  final MediaModelsStore? _store;
  final MediaKeyResolver? _resolveKey;
  final http.Client? _httpClient;

  /// Resolves the endpoint for [slot] (see [MediaModelsStore.resolve]);
  /// null when no usable endpoint exists.
  Future<MediaEndpoint?> endpointFor(String slot) async {
    final store = _store ?? await MediaModelsStore.load(env);
    return store.resolve(slot, _fallback(), resolveKey: _resolveKey);
  }

  /// Generates an image on the [MediaSlot.imageGeneration] endpoint
  /// (OpenAI-compatible `POST /images/generations`, `b64_json` response;
  /// providers that answer with a URL are fetched instead) and saves the
  /// PNG into [generatedMediaDir].
  Future<GeneratedMediaFile> generateImage({
    required String prompt,
    String? size,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) throw StateError('prompt is required');
    final endpoint = await _requireEndpoint(MediaSlot.imageGeneration);
    final body = <String, Object?>{
      'model': endpoint.modelId,
      'prompt': trimmed,
      'n': 1,
      'response_format': 'b64_json',
      if (size != null && size.trim().isNotEmpty) 'size': size.trim(),
    };
    final decoded = await _postJson(
      endpoint,
      '/images/generations',
      body,
      what: 'Image generation',
    );
    final first = _firstDataEntry(decoded, what: 'Image generation');
    final bytes = await _payloadBytes(first, endpoint, what: 'Image');
    return _save('image', 'png', bytes, detail: size ?? 'default size');
  }

  /// Synthesizes speech on the [MediaSlot.audioTts] endpoint
  /// (OpenAI-compatible `POST /audio/speech`, binary mp3 response) and
  /// saves it into [generatedMediaDir].
  Future<GeneratedMediaFile> speak({
    required String text,
    String? voice,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw StateError('text is required');
    final endpoint = await _requireEndpoint(MediaSlot.audioTts);
    final usedVoice = (voice == null || voice.trim().isEmpty)
        ? 'alloy'
        : voice.trim();
    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse('${endpoint.baseUrl}/audio/speech'),
        headers: {
          'authorization': 'Bearer ${endpoint.apiKey}',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': endpoint.modelId,
          'input': trimmed,
          'voice': usedVoice,
          'response_format': 'mp3',
        }),
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        'Speech synthesis failed (HTTP ${response.statusCode}): '
        '${response.body.trim()}',
      );
    }
    return _save(
      'speech',
      'mp3',
      response.bodyBytes,
      detail: 'voice "$usedVoice"',
    );
  }

  /// Generates music on the [MediaSlot.musicGeneration] endpoint and saves
  /// the audio into [generatedMediaDir].
  ///
  /// Music generation is NOT an OpenAI standard, so the endpoint is
  /// user-configured and must conform to an OpenAI-images-style contract:
  /// `POST {baseUrl}/music/generations` with `{model, prompt, duration}`
  /// answering `{data: [{b64_json | url}]}` (audio bytes base64-encoded, or
  /// a URL to fetch). Without a configured slot the call fails with an
  /// actionable error — there is no main-connection fallback.
  Future<GeneratedMediaFile> generateMusic({
    required String prompt,
    int? seconds,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) throw StateError('prompt is required');
    final endpoint = await _requireEndpoint(MediaSlot.musicGeneration);
    final duration = seconds == null || seconds < 1 ? 30 : seconds;
    final decoded = await _postJson(endpoint, '/music/generations', {
      'model': endpoint.modelId,
      'prompt': trimmed,
      'duration': duration,
    }, what: 'Music generation');
    final first = _firstDataEntry(decoded, what: 'Music generation');
    final bytes = await _payloadBytes(first, endpoint, what: 'Music');
    return _save('music', 'mp3', bytes, detail: '$duration s requested');
  }

  /// The shared "no usable endpoint" error: points at the slot in
  /// `media_models.json` (and, for the main-connection fallback, at the
  /// provider requirements).
  Future<MediaEndpoint> _requireEndpoint(String slot) async {
    final endpoint = await endpointFor(slot);
    if (endpoint != null) return endpoint;
    final store = _store ?? await MediaModelsStore.load(env);
    final override = store.overrideFor(slot);
    if (override != null) {
      throw StateError(
        'The "$slot" endpoint in ${MediaModelsStore.fileName} is not '
        'usable — it needs providerKind "openai-completions", a modelId, '
        'and a resolvable API key'
        '${override.apiKeyName != null ? ' (named "${override.apiKeyName}" — save it in the Fa settings Keys section)' : ''}.',
      );
    }
    throw StateError(
      'No $slot endpoint is configured. Either connect an '
      'OpenAI-compatible provider in the Fa settings, or add a "$slot" '
      'slot to ${MediaModelsStore.fileName} '
      '({providerKind, baseUrl, modelId, apiKeyName?}).',
    );
  }

  Future<Map<String, dynamic>> _postJson(
    MediaEndpoint endpoint,
    String path,
    Map<String, Object?> body, {
    required String what,
  }) async {
    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse('${endpoint.baseUrl}$path'),
        headers: {
          'authorization': 'Bearer ${endpoint.apiKey}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        '$what failed (HTTP ${response.statusCode}): ${response.body.trim()}',
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // fall through
    }
    throw StateError('$what returned an unexpected response (not JSON).');
  }

  static Map<String, dynamic> _firstDataEntry(
    Map<String, dynamic> decoded, {
    required String what,
  }) {
    final data = decoded['data'];
    if (data is List && data.isNotEmpty && data.first is Map) {
      return (data.first as Map).cast<String, dynamic>();
    }
    throw StateError('$what returned no media payload.');
  }

  /// The media bytes of one `data[]` entry: inline base64 (`b64_json`, or
  /// `b64_audio` on music variants) or a URL to fetch.
  Future<Uint8List> _payloadBytes(
    Map<String, dynamic> entry,
    MediaEndpoint endpoint, {
    required String what,
  }) async {
    final b64 = (entry['b64_json'] ?? entry['b64_audio'])?.toString();
    if (b64 != null && b64.isNotEmpty) {
      return base64Decode(b64);
    }
    final url = entry['url']?.toString();
    if (url != null && url.isNotEmpty) {
      final client = _httpClient ?? http.Client();
      final http.Response response;
      try {
        response = await client.get(Uri.parse(url));
      } finally {
        if (_httpClient == null) client.close();
      }
      if (response.statusCode != 200) {
        throw StateError(
          '$what download failed (HTTP ${response.statusCode}) for $url',
        );
      }
      return response.bodyBytes;
    }
    throw StateError('$what returned neither b64_json nor a URL.');
  }

  Future<GeneratedMediaFile> _save(
    String prefix,
    String extension,
    Uint8List bytes, {
    required String detail,
  }) async {
    final dirResult = await env.createDir(generatedMediaDir);
    if (dirResult.isErr) {
      throw StateError(
        'Could not create $generatedMediaDir: '
        '${dirResult.errorOrNull!.message}',
      );
    }
    final path =
        '$generatedMediaDir/$prefix-${DateTime.now().millisecondsSinceEpoch}.$extension';
    final writeResult = await env.writeBinaryFile(path, bytes);
    if (writeResult.isErr) {
      throw StateError(
        'Could not store the generated file: '
        '${writeResult.errorOrNull!.message}',
      );
    }
    return GeneratedMediaFile(path: path, bytes: bytes, detail: detail);
  }
}

/// Name of the agent tool that generates an image.
const generateImageToolName = 'generate_image';

/// Name of the agent tool that synthesizes speech.
const speakToolName = 'speak';

/// Name of the agent tool that generates music.
const generateMusicToolName = 'generate_music';

/// Creates the `generate_image` tool bound to [gateway].
///
/// Tier write: it spends API quota and writes a file, so the approval gate
/// applies. Texts are LLM-facing and stay literal English.
AgentTool generateImageTool(MediaGateway gateway) {
  return AgentTool(
    name: generateImageToolName,
    label: generateImageToolName,
    tier: ApprovalTier.write,
    description:
        'Generate an image from a text prompt. Uses the configured '
        'imageGeneration endpoint (media_models.json override, or the '
        'connected provider when it is OpenAI-compatible). Saves a PNG into '
        'the sandbox generated/ folder and returns its path — show it to '
        'the user or reference it from a JS app.',
    parameters: const {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'Text description of the image (required)',
        },
        'size': {
          'type': 'string',
          'description':
              'Image size, e.g. "1024x1024", "1024x1792", "1792x1024" '
              '(provider-dependent; default: provider default)',
        },
      },
      'required': ['prompt'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      try {
        final file = await gateway.generateImage(
          prompt: (arguments['prompt'] ?? '').toString(),
          size: arguments['size']?.toString(),
        );
        return ToolExecutionResult.text(
          'Generated image saved to ${file.path} '
          '(${file.bytes.length} bytes, ${file.detail}).',
        );
      } on Object catch (error) {
        return ToolExecutionResult.text(_errorText(error));
      }
    },
  );
}

/// Creates the `speak` tool bound to [gateway].
///
/// Tier write (API quota + file write), same as [generateImageTool].
AgentTool speakTool(MediaGateway gateway) {
  return AgentTool(
    name: speakToolName,
    label: speakToolName,
    tier: ApprovalTier.write,
    description:
        'Convert text to speech. Uses the configured audioTts endpoint '
        '(media_models.json override, or the connected provider when it is '
        'OpenAI-compatible). Saves an mp3 into the sandbox generated/ '
        'folder and returns its path.',
    parameters: const {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'The text to speak (required)',
        },
        'voice': {
          'type': 'string',
          'description':
              'Voice name (provider-dependent, e.g. "alloy", "nova"; '
              'default: "alloy")',
        },
      },
      'required': ['text'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      try {
        final file = await gateway.speak(
          text: (arguments['text'] ?? '').toString(),
          voice: arguments['voice']?.toString(),
        );
        // Rough duration hint: mp3 at ~128 kbps ≈ 16 KB per second.
        final seconds = (file.bytes.length / 16000).round();
        return ToolExecutionResult.text(
          'Speech saved to ${file.path} '
          '(${file.bytes.length} bytes, ${file.detail}, ~${seconds}s).',
        );
      } on Object catch (error) {
        return ToolExecutionResult.text(_errorText(error));
      }
    },
  );
}

/// Creates the `generate_music` tool bound to [gateway].
///
/// Music generation has no OpenAI standard, so the tool only works with a
/// configured `musicGeneration` slot; the description documents the
/// expected endpoint shape so custom endpoints can conform.
AgentTool generateMusicTool(MediaGateway gateway) {
  return AgentTool(
    name: generateMusicToolName,
    label: generateMusicToolName,
    tier: ApprovalTier.write,
    description:
        'Generate music from a text prompt. Requires a musicGeneration '
        'endpoint configured in media_models.json (music generation is not '
        'an OpenAI standard — there is no provider fallback). The endpoint '
        'must accept POST {baseUrl}/music/generations with a JSON body '
        '{model, prompt, duration} and answer like the OpenAI images API: '
        '{"data": [{"b64_json": "<audio base64>"}]} or {"data": [{"url": '
        '"<audio url>"}]}. Saves an mp3 into the sandbox generated/ folder '
        'and returns its path.',
    parameters: const {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'Description of the music to generate (required)',
        },
        'seconds': {
          'type': 'integer',
          'description': 'Requested duration in seconds (default: 30)',
        },
      },
      'required': ['prompt'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      try {
        final file = await gateway.generateMusic(
          prompt: (arguments['prompt'] ?? '').toString(),
          seconds: (arguments['seconds'] as num?)?.toInt(),
        );
        return ToolExecutionResult.text(
          'Music saved to ${file.path} '
          '(${file.bytes.length} bytes, ${file.detail}).',
        );
      } on Object catch (error) {
        return ToolExecutionResult.text(_errorText(error));
      }
    },
  );
}

/// Renders a caught error as LLM-facing text (StateError messages are the
/// actionable ones; anything else is stringified).
String _errorText(Object error) =>
    'Error: ${error is StateError ? error.message : error}';
