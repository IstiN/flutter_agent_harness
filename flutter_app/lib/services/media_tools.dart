// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import 'package:fa/services/analytics.dart';
import 'package:fa/services/media_models_store.dart';

// The tool-name constants live in the fa_ui package (the shared chat
// message tile keys its inline rendering off them); re-exported here so
// existing `media_tools.dart` imports keep working.
import 'package:fa_ui/fa_ui.dart'
    show generateImageToolName, speakToolName, generateMusicToolName;
export 'package:fa_ui/fa_ui.dart'
    show generateImageToolName, speakToolName, generateMusicToolName;

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
/// Shared by the agent's `generate_image` / `speak` / `generate_music` /
/// `generate_video` tools and the `jsr.fa.media.*` JS bridge so both
/// resolve endpoints identically. The store is (re)loaded per call when none was injected, so
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
    Duration videoPollInterval = const Duration(seconds: 3),
    Duration videoPollTimeout = const Duration(minutes: 4),
  }) : _fallback = fallback,
       _store = store,
       _resolveKey = resolveKey,
       _httpClient = httpClient,
       _videoPollInterval = videoPollInterval,
       _videoPollTimeout = videoPollTimeout;

  /// The sandbox filesystem generated files land in.
  final ExecutionEnv env;

  final MediaFallback Function() _fallback;
  final MediaModelsStore? _store;
  final MediaKeyResolver? _resolveKey;
  final http.Client? _httpClient;

  /// How often [generateVideo] polls the job status (injectable for tests).
  final Duration _videoPollInterval;

  /// How long [generateVideo] waits for a job before failing (injectable
  /// for tests).
  final Duration _videoPollTimeout;

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
    if (_isGoogleEndpoint(endpoint)) {
      throw StateError(
        'Image generation is not supported for the Google provider yet — '
        'point the imageGeneration slot at an OpenAI-compatible endpoint.',
      );
    }
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
  /// saves it into [generatedMediaDir]. A Google (`generativelanguage`)
  /// endpoint speaks the native Gemini TTS protocol instead:
  /// `POST /models/{model}:generateContent` with `x-goog-api-key`, answering
  /// base64 LINEAR16 PCM (24 kHz mono) that is wrapped in a WAV header and
  /// saved as `.wav`.
  ///
  /// The voice resolves in order: an explicit [voice] argument, the slot
  /// override's configured voice, then `alloy` (`Kore` on Google endpoints).
  Future<GeneratedMediaFile> speak({
    required String text,
    String? voice,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw StateError('text is required');
    final endpoint = await _requireEndpoint(MediaSlot.audioTts);
    final argument = voice?.trim();
    final configured = endpoint.voice?.trim();
    if (_isGoogleEndpoint(endpoint)) {
      final googleVoice = argument != null && argument.isNotEmpty
          ? argument
          : (configured != null && configured.isNotEmpty ? configured : 'Kore');
      return _speakGoogle(endpoint, trimmed, googleVoice);
    }
    final usedVoice = argument != null && argument.isNotEmpty
        ? argument
        : (configured != null && configured.isNotEmpty ? configured : 'alloy');
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

  /// The Google-native speech path (see [speak]): Gemini TTS over
  /// `generateContent`, PCM wrapped as WAV.
  Future<GeneratedMediaFile> _speakGoogle(
    MediaEndpoint endpoint,
    String text,
    String voice,
  ) async {
    final decoded = await _postJson(
      endpoint,
      '/models/${endpoint.modelId}:generateContent',
      {
        'contents': [
          {
            'parts': [
              {'text': text},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voice},
            },
          },
        },
      },
      what: 'Speech synthesis',
      googleApiKey: true,
    );
    final pcm = _googleInlineAudioBytes(decoded, what: 'Speech synthesis');
    return _save('speech', 'wav', _wrapPcmInWav(pcm), detail: 'voice "$voice"');
  }

  /// Generates music on the [MediaSlot.musicGeneration] endpoint and saves
  /// the audio into [generatedMediaDir].
  ///
  /// Music generation is NOT an OpenAI standard, so the endpoint is
  /// user-configured and must conform to an OpenAI-images-style contract:
  /// `POST {baseUrl}/music/generations` with `{model, prompt, duration}`
  /// answering `{data: [{b64_json | url}]}` (audio bytes base64-encoded, or
  /// a URL to fetch). A Google (`generativelanguage`) endpoint instead gets
  /// `POST {baseUrl}/interactions` with `{model, input}`; the base64 audio
  /// is deep-searched in the response. Without a configured slot the call
  /// fails with an actionable error — there is no main-connection fallback.
  Future<GeneratedMediaFile> generateMusic({
    required String prompt,
    int? seconds,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) throw StateError('prompt is required');
    final endpoint = await _requireEndpoint(MediaSlot.musicGeneration);
    final duration = seconds == null || seconds < 1 ? 30 : seconds;
    if (_isGoogleEndpoint(endpoint)) {
      final decoded = await _postJson(
        endpoint,
        '/interactions',
        {'model': endpoint.modelId, 'input': trimmed},
        what: 'Music generation',
        googleApiKey: true,
      );
      final b64 = _deepFindAudioBase64(decoded);
      if (b64 == null) {
        throw StateError('Music generation returned no audio payload.');
      }
      return _save(
        'music',
        'mp3',
        base64Decode(b64),
        detail: '$duration s requested',
      );
    }
    final decoded = await _postJson(endpoint, '/music/generations', {
      'model': endpoint.modelId,
      'prompt': trimmed,
      'duration': duration,
    }, what: 'Music generation');
    final first = _firstDataEntry(decoded, what: 'Music generation');
    final bytes = await _payloadBytes(first, endpoint, what: 'Music');
    return _save('music', 'mp3', bytes, detail: '$duration s requested');
  }

  /// Generates a video clip on the [MediaSlot.videoGeneration] endpoint and
  /// saves the mp4 into [generatedMediaDir].
  ///
  /// Video generation is asynchronous, so the endpoint must follow the
  /// OpenAI/OpenRouter videos contract: `POST {baseUrl}/videos` with
  /// `{model, prompt, duration?, size?}` answers a job `{id, status}`
  /// (200 or 202 Accepted); the job is polled at its `polling_url` (or
  /// `GET {baseUrl}/videos/{id}`) every [videoPollInterval] until a
  /// terminal status — `completed` downloads the mp4 (from the job's
  /// `unsigned_urls`/`url` when present, otherwise
  /// `GET {baseUrl}/videos/{id}/content`), `failed`/`cancelled`/`expired`
  /// is an error — giving up after [videoPollTimeout]. [cancelToken] aborts
  /// the wait between polls. Without a configured slot the call fails with
  /// an actionable error — there is no main-connection fallback.
  Future<GeneratedMediaFile> generateVideo({
    required String prompt,
    int? seconds,
    String? size,
    CancelToken? cancelToken,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) throw StateError('prompt is required');
    final endpoint = await _requireEndpoint(MediaSlot.videoGeneration);
    cancelToken?.throwIfCancelled();
    if (_isGoogleEndpoint(endpoint)) {
      throw StateError(
        'Video generation is not supported for the Google provider yet — '
        'point the videoGeneration slot at an OpenAI-compatible endpoint.',
      );
    }
    final usedSeconds = seconds != null && seconds > 0 ? seconds : null;
    final usedSize = size != null && size.trim().isNotEmpty
        ? size.trim()
        : null;
    final created = await _postJson(
      endpoint,
      '/videos',
      {
        'model': endpoint.modelId,
        'prompt': trimmed,
        if (usedSeconds != null) 'duration': usedSeconds,
        if (usedSize != null) 'size': usedSize,
      },
      what: 'Video generation',
      okStatuses: const {200, 202},
    );
    final jobId = created['id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw StateError('Video generation returned no job id.');
    }
    final pollingUrl = created['polling_url']?.toString();
    final pollUri = Uri.parse(
      pollingUrl != null && pollingUrl.isNotEmpty
          ? pollingUrl
          : '${endpoint.baseUrl}/videos/$jobId',
    );
    final deadline = DateTime.now().add(_videoPollTimeout);
    final job = await _pollVideoJob(
      pollUri,
      endpoint,
      jobId,
      deadline,
      cancelToken,
    );
    final bytes = await _videoBytes(job, endpoint, jobId);
    final detail = [
      if (usedSeconds != null) '${usedSeconds}s',
      if (usedSize != null) usedSize,
    ];
    return _save(
      'video',
      'mp4',
      bytes,
      detail: detail.isEmpty ? 'provider defaults' : detail.join(', '),
    );
  }

  /// Polls the video job at [pollUri] until it reaches a terminal status,
  /// returning the completed job payload. `failed`/`cancelled`/`expired`
  /// jobs and the [deadline] are [StateError]s; [cancelToken] aborts the
  /// wait between polls.
  Future<Map<String, dynamic>> _pollVideoJob(
    Uri pollUri,
    MediaEndpoint endpoint,
    String jobId,
    DateTime deadline,
    CancelToken? cancelToken,
  ) async {
    for (;;) {
      cancelToken?.throwIfCancelled();
      final job = await _getJson(pollUri, endpoint, what: 'Video generation');
      final status = job['status']?.toString() ?? '';
      if (status == 'completed' || status == 'succeeded') return job;
      if (status == 'failed' || status == 'cancelled' || status == 'expired') {
        final error = job['error'];
        throw StateError(
          'Video generation job $status${error == null ? '' : ': $error'}.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Video generation timed out after '
          '${(_videoPollTimeout.inSeconds / 60).round()} minutes '
          '(job $jobId is still "$status").',
        );
      }
      await _pollSleep(cancelToken);
    }
  }

  /// Waits [_videoPollInterval] between job status polls, waking early when
  /// [cancelToken] is cancelled.
  Future<void> _pollSleep(CancelToken? cancelToken) async {
    if (cancelToken == null) {
      await Future<void>.delayed(_videoPollInterval);
      return;
    }
    await Future.any<void>([
      Future<void>.delayed(_videoPollInterval),
      cancelToken.onCancel,
    ]);
    cancelToken.throwIfCancelled();
  }

  /// The mp4 bytes of a completed video job: an explicit URL from the job
  /// (`unsigned_urls` first, then `url`) fetched as-is, otherwise the
  /// authenticated content endpoint.
  Future<Uint8List> _videoBytes(
    Map<String, dynamic> job,
    MediaEndpoint endpoint,
    String jobId,
  ) async {
    String? url;
    final unsigned = job['unsigned_urls'];
    if (unsigned is List && unsigned.isNotEmpty) {
      url = unsigned.first?.toString();
    }
    url ??= job['url']?.toString();
    final authed = url == null || url.isEmpty;
    final uri = Uri.parse(
      authed ? '${endpoint.baseUrl}/videos/$jobId/content' : url,
    );
    // OpenRouter fills the completed job's `url` with the AUTHENTICATED
    // content endpoint (.../videos/<id>/content?index=0) rather than a
    // public link — fetching it "as-is" 401s. Send the key whenever the
    // URL lives on the endpoint's origin; truly public URLs skip it.
    final endpointHost = Uri.tryParse(endpoint.baseUrl)?.host;
    final sendAuth = authed || uri.host == endpointHost;
    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.get(
        uri,
        headers: sendAuth
            ? {'authorization': 'Bearer ${endpoint.apiKey}'}
            : null,
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        'Video download failed (HTTP ${response.statusCode}) for $uri',
      );
    }
    return response.bodyBytes;
  }

  /// Authenticated JSON GET (the video job status poll), with the same
  /// error contract as [_postJson].
  Future<Map<String, dynamic>> _getJson(
    Uri uri,
    MediaEndpoint endpoint, {
    required String what,
  }) async {
    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.get(
        uri,
        headers: {'authorization': 'Bearer ${endpoint.apiKey}'},
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        '$what status poll failed (HTTP ${response.statusCode}): '
        '${response.body.trim()}',
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // fall through
    }
    throw StateError(
      '$what status poll returned an unexpected response (not JSON).',
    );
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
    Set<int> okStatuses = const {200},
    bool googleApiKey = false,
  }) async {
    final client = _httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse('${endpoint.baseUrl}$path'),
        headers: googleApiKey
            ? {
                'x-goog-api-key': endpoint.apiKey,
                'content-type': 'application/json',
              }
            : {
                'authorization': 'Bearer ${endpoint.apiKey}',
                'content-type': 'application/json',
              },
        body: jsonEncode(body),
      );
    } finally {
      if (_httpClient == null) client.close();
    }
    if (!okStatuses.contains(response.statusCode)) {
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

  /// True when [endpoint] points at Google's Generative Language API — the
  /// media calls then speak the native Gemini protocol (and authenticate
  /// with `x-goog-api-key`) instead of the OpenAI-compatible one.
  static bool _isGoogleEndpoint(MediaEndpoint endpoint) =>
      endpoint.baseUrl.contains('generativelanguage');

  /// The audio bytes of a Gemini `generateContent` response:
  /// `candidates[].content.parts[].inlineData.data` (base64).
  static Uint8List _googleInlineAudioBytes(
    Map<String, dynamic> decoded, {
    required String what,
  }) {
    final candidates = decoded['candidates'];
    if (candidates is List) {
      for (final candidate in candidates) {
        if (candidate is! Map) continue;
        final content = candidate['content'];
        if (content is! Map) continue;
        final parts = content['parts'];
        if (parts is! List) continue;
        for (final part in parts) {
          if (part is! Map) continue;
          final inline = part['inlineData'] ?? part['inline_data'];
          if (inline is! Map) continue;
          final data = inline['data'];
          if (data is String && data.isNotEmpty) return base64Decode(data);
        }
      }
    }
    throw StateError('$what returned no audio payload.');
  }

  /// Deep-searches a decoded JSON tree for base64 audio: `b64_json`, a
  /// content block with `type: "audio"`, or an `output_audio`/`outputAudio`/
  /// `audio`/`inlineData` map carrying a non-empty `data` string.
  static String? _deepFindAudioBase64(Object? node) {
    if (node is Map) {
      final b64 = node['b64_json'];
      if (b64 is String && b64.isNotEmpty) return b64;
      for (final key in const [
        'output_audio',
        'outputAudio',
        'audio',
        'inlineData',
        'inline_data',
      ]) {
        final value = node[key];
        if (value is Map) {
          final data = value['data'];
          if (data is String && data.isNotEmpty) return data;
        }
      }
      if (node['type'] == 'audio') {
        final data = node['data'];
        if (data is String && data.isNotEmpty) return data;
      }
      for (final value in node.values) {
        final found = _deepFindAudioBase64(value);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _deepFindAudioBase64(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Wraps raw LINEAR16 PCM (24 kHz mono — the Gemini TTS output format) in
  /// a 44-byte RIFF/WAVE header so the bytes play as a `.wav` file.
  static Uint8List _wrapPcmInWav(Uint8List pcm, {int sampleRate = 24000}) {
    const channels = 1;
    const bitsPerSample = 16;
    const blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(44);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        header.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // PCM chunk size
    header.setUint16(20, 1, Endian.little); // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * blockAlign, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcm]);
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
    // The file prefixes are 'image'/'speech'/'music'/'video'; the event
    // kinds follow the tool names ('speak' for speech).
    AppAnalytics.instance.mediaGenerated(prefix == 'speech' ? 'speak' : prefix);
    return GeneratedMediaFile(path: path, bytes: bytes, detail: detail);
  }
}

/// Name of the agent tool that generates a video clip.
const generateVideoToolName = 'generate_video';

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
        'the sandbox generated/ folder and returns its path — reference it '
        'in your reply as ![alt](<path>) to display it inline in the chat, '
        'or from a JS app.',
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
          '(${file.bytes.length} bytes, ${file.detail}). '
          'Reference it as ![image](${file.path}) to display it inline in '
          'the chat.',
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
        'OpenAI-compatible; a Google generativelanguage endpoint is called '
        'with the native Gemini TTS protocol). Saves the audio (mp3, wav on '
        'the Google provider) into the sandbox generated/ folder and '
        'returns its path.',
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
              'default: the audioTts slot\'s configured voice, else "alloy")',
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
        // Rough duration hint: mp3 at ~128 kbps ≈ 16 KB/s; the Google TTS
        // wav (LINEAR16 PCM, 24 kHz mono) is 48 KB/s.
        final bytesPerSecond = file.path.endsWith('.wav') ? 48000 : 16000;
        final seconds = (file.bytes.length / bytesPerSecond).round();
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
        '"<audio url>"}]}. A Google (generativelanguage) endpoint is called '
        'via POST {baseUrl}/interactions with {model, input} instead. Saves '
        'an mp3 into the sandbox generated/ folder and returns its path.',
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

/// Creates the `generate_video` tool bound to [gateway].
///
/// Video generation has no main-connection fallback, so the tool only works
/// with a configured `videoGeneration` slot; the description documents the
/// async endpoint contract so custom endpoints can conform. Generation can
/// take minutes — the gateway polls the job to completion inside the tool
/// call (honoring the cancel token).
AgentTool generateVideoTool(MediaGateway gateway) {
  return AgentTool(
    name: generateVideoToolName,
    label: generateVideoToolName,
    tier: ApprovalTier.write,
    description:
        'Generate a video clip from a text prompt. Requires a '
        'videoGeneration endpoint configured in media_models.json (video '
        'generation is asynchronous — there is no provider fallback). The '
        'endpoint must follow the OpenAI/OpenRouter videos contract: POST '
        '{baseUrl}/videos with a JSON body {model, prompt, duration?, '
        'size?} answers a job {id, status}, polled at GET '
        '{baseUrl}/videos/{id} until completed/failed; the mp4 comes from '
        'the job\'s unsigned_urls or GET {baseUrl}/videos/{id}/content. '
        'Generation can take several minutes. Saves an mp4 into the sandbox '
        'generated/ folder and returns its path.',
    parameters: const {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description':
              'Text description of the video to generate (required) — '
              'include motion, camera, and scene details',
        },
        'seconds': {
          'type': 'integer',
          'description':
              'Requested clip length in seconds (provider-dependent, short '
              'clips of 4-16s are typical; capped at 30; default: provider '
              'default)',
        },
        'size': {
          'type': 'string',
          'description':
              'Pixel dimensions as "WIDTHxHEIGHT", e.g. "1280x720" '
              '(landscape) or "720x1280" (portrait; provider-dependent, '
              'default: provider default)',
        },
      },
      'required': ['prompt'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      try {
        final seconds = (arguments['seconds'] as num?)?.toInt().clamp(1, 30);
        final file = await gateway.generateVideo(
          prompt: (arguments['prompt'] ?? '').toString(),
          seconds: seconds?.toInt(),
          size: arguments['size']?.toString(),
          cancelToken: cancelToken,
        );
        return ToolExecutionResult.text(
          'Video saved to ${file.path} '
          '(${file.bytes.length} bytes, ${file.detail}).',
        );
      } on CancelledException {
        rethrow;
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
