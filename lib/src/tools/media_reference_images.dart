/// Multimodal media inputs and capability discovery (gh-1844).
///
/// Shared by the `generate_image` / `generate_video` tools (CLI) and the
/// app's `MediaGateway`: reference images arrive as sandbox paths,
/// http(s) URLs, or base64 (raw or `data:` URLs), are validated against
/// the same guards the chat image pipeline uses (magic-byte sniffing from
/// `paste_image.dart`, a per-image byte cap, a per-request count cap),
/// and are rendered as OpenRouter `image_url` parts (data URLs for local
/// bytes, plain URLs passthrough).
///
/// Capability checks are CAPABILITY-DRIVEN, never model-name-driven
/// (gh-1844 AC5): a slot override may DECLARE its modalities
/// (`input: [text, image]`); OpenRouter endpoints can be DISCOVERED from
/// the `/api/v1/models` metadata (`architecture.input_modalities`);
/// endpoints with declared/discovered modalities that lack `image` reject
/// reference images with an actionable error BEFORE the generation call.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cli/paste_image.dart' show maxPasteImageBytes, sniffImageMime;
import '../env/execution_env.dart';
import 'generate_image.dart' show MediaException;

/// The maximum number of reference images one media call accepts
/// (OpenRouter allows up to 10 for image generation; the count cap keeps
/// request bodies sane for every dialect).
const maxMediaImageReferences = 10;

/// The default mime type for base64 inputs whose bytes carry no known
/// magic-byte signature.
const defaultImageMimeType = 'image/png';

/// One reference image argument, before resolution.
sealed class MediaImageInput {
  const MediaImageInput();

  /// A sandbox-relative (or absolute) local image path.
  const factory MediaImageInput.path(String path) = MediaImagePath;

  /// An http(s) URL the provider fetches itself.
  const factory MediaImageInput.url(String url) = MediaImageUrl;

  /// Raw base64 image data (mime sniffed from the decoded bytes).
  const factory MediaImageInput.base64(String base64) = MediaImageBase64;
}

/// Local sandbox path variant of [MediaImageInput].
final class MediaImagePath extends MediaImageInput {
  const MediaImagePath(this.path);

  /// The sandbox path to read.
  final String path;
}

/// http(s) URL variant of [MediaImageInput].
final class MediaImageUrl extends MediaImageInput {
  const MediaImageUrl(this.url);

  /// The URL passed through to the provider.
  final String url;
}

/// Raw base64 variant of [MediaImageInput].
final class MediaImageBase64 extends MediaImageInput {
  const MediaImageBase64(this.base64);

  /// The base64-encoded image bytes.
  final String base64;
}

/// Parses one tool-argument string into a [MediaImageInput]:
/// `data:` URLs, http(s) URLs, and bare base64 (a long base64-ish string
/// without path separators) become the matching variants; anything else is
/// a sandbox path.
MediaImageInput parseMediaImageInput(String raw) {
  final value = raw.trim();
  if (value.isEmpty) {
    throw MediaException('reference image entries must be non-empty');
  }
  if (value.startsWith('b64:')) {
    final data = value.substring(4);
    if (data.isEmpty) {
      throw MediaException(
        'b64: reference image is missing its payload',
      );
    }
    return MediaImageInput.base64(data);
  }
  if (value.startsWith('data:image/')) {
    final comma = value.indexOf(',');
    if (comma < 0) {
      throw MediaException('data URL reference image is missing its payload');
    }
    final payload = value.substring(comma + 1);
    if (payload.isEmpty) {
      throw MediaException('data URL reference image is missing its payload');
    }
    return MediaImageInput.base64(payload);
  }
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return MediaImageInput.url(value);
  }
  // A bare base64 payload: long, no path separators, decodable.
  if (value.length >= 64 && !value.contains('/') && _looksLikeBase64(value)) {
    return MediaImageInput.base64(value);
  }
  return MediaImageInput.path(value);
}

bool _looksLikeBase64(String value) {
  for (final code in value.codeUnits) {
    final c = code;
    final ok =
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2B || // +
        c == 0x2F || // /
        c == 0x3D; // =
    if (!ok) return false;
  }
  return true;
}

/// A resolved reference image ready for the wire: either a provider-side
/// URL or a base64 data URL with a sniffed mime type.
final class ResolvedMediaImage {
  const ResolvedMediaImage._({required this.url, required this.mimeType});

  /// An http(s) URL the provider fetches.
  factory ResolvedMediaImage.remote(String url) =>
      ResolvedMediaImage._(url: url, mimeType: '');

  /// Base64 bytes inlined as a `data:` URL (mime sniffed from the bytes).
  factory ResolvedMediaImage.inline(List<int> bytes) {
    if (bytes.length > maxPasteImageBytes) {
      throw MediaException(
        'reference image is too large: ${bytes.length} bytes '
        '(cap $maxPasteImageBytes) — downscale the image',
      );
    }
    final mime = sniffImageMime(bytes) ?? defaultImageMimeType;
    return ResolvedMediaImage._(
      url: 'data:$mime;base64,${base64Encode(bytes)}',
      mimeType: mime,
    );
  }

  /// The `image_url` value sent to the provider.
  final String url;

  /// The sniffed mime type; empty for remote URLs (the provider sniffs).
  final String mimeType;

  /// The OpenRouter `input_references` / `frame_images` entry shape.
  Map<String, dynamic> toOpenRouterJson() => {
    'type': 'image_url',
    'image_url': {'url': url},
  };
}

/// Resolves [inputs] against the guards: the count cap, per-image byte cap
/// (inline variants), readable sandbox paths, and base64 that decodes.
/// URLs pass through untouched (the provider validates them).
Future<List<ResolvedMediaImage>> resolveMediaImageInputs(
  ExecutionEnv env,
  List<MediaImageInput> inputs,
) async {
  if (inputs.length > maxMediaImageReferences) {
    throw MediaException(
      'too many reference images: ${inputs.length} '
      '(cap $maxMediaImageReferences)',
    );
  }
  final resolved = <ResolvedMediaImage>[];
  for (final input in inputs) {
    switch (input) {
      case MediaImageUrl():
        resolved.add(ResolvedMediaImage.remote(input.url));
      case MediaImageBase64():
        final bytes = _tryBase64Decode(input.base64);
        if (bytes == null) {
          throw MediaException('reference image is not valid base64');
        }
        resolved.add(ResolvedMediaImage.inline(bytes));
      case MediaImagePath():
        final read = await env.readBinaryFile(input.path);
        if (read.isErr) {
          throw MediaException(
            'cannot read reference image at "${input.path}": '
            '${read.errorOrNull}',
          );
        }
        resolved.add(ResolvedMediaImage.inline(read.valueOrNull!));
    }
  }
  return resolved;
}

List<int>? _tryBase64Decode(String value) {
  try {
    return base64Decode(value);
  } on FormatException {
    return null;
  }
}

/// The discovered capabilities of one endpoint's model.
final class EndpointCapabilities {
  const EndpointCapabilities({this.input = const [], this.output = const []});

  /// Input modalities the endpoint accepts (e.g. `text`, `image`, `video`).
  final List<String> input;

  /// Output modalities the endpoint produces (e.g. `image`, `video`).
  final List<String> output;

  /// True when [input] declares `image`.
  bool get acceptsImages => input.contains('image');
}

/// Parses OpenRouter `/api/v1/models` metadata for [modelId]'s
/// architecture: `architecture.input_modalities` / `output_modalities`.
/// Returns null when the model is absent or carries no architecture —
/// capability discovery must degrade to "unknown", never to a guess.
EndpointCapabilities? parseOpenRouterCapabilities(
  Map<String, dynamic> modelsJson,
  String modelId,
) {
  final data = modelsJson['data'];
  if (data is! List) return null;
  for (final entry in data) {
    if (entry is! Map) continue;
    if (entry['id'] != modelId) continue;
    final architecture = entry['architecture'];
    if (architecture is! Map) return null;
    return EndpointCapabilities(
      input: _modalityList(architecture['input_modalities']),
      output: _modalityList(architecture['output_modalities']),
    );
  }
  return null;
}

List<String> _modalityList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final entry in value)
      if (entry is String) entry,
  ];
}

/// True when [baseUrl] points at an OpenRouter host (capability discovery
/// and the OpenRouter dialects key off this, never off model names).
bool isOpenRouterBaseUrl(String baseUrl) {
  final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
  return host == 'openrouter.ai' || host.endsWith('.openrouter.ai');
}

/// The OpenRouter model-metadata URL for [baseUrl]'s origin
/// (`{origin}/api/v1/models`).
Uri openRouterModelsUri(String baseUrl) {
  final uri = Uri.parse(baseUrl);
  return Uri(
    scheme: uri.scheme.isEmpty ? 'https' : uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: '/api/v1/models',
  );
}

/// Resolves the effective input modalities for a media call:
/// [declared] (the slot override's `input:` list) wins; otherwise
/// OpenRouter endpoints are DISCOVERED from the model metadata
/// (`null` when the discovery is unavailable — unknown means "let the
/// provider validate", declared/discovered means "check before the call").
Future<List<String>?> resolveInputModalities({
  required String baseUrl,
  required String apiKey,
  required String modelId,
  List<String> declared = const [],
  required http.Client client,
}) async {
  if (declared.isNotEmpty) return declared;
  if (!isOpenRouterBaseUrl(baseUrl)) return null;
  try {
    final response = await client.get(
      openRouterModelsUri(baseUrl),
      headers: {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
    );
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final capabilities = parseOpenRouterCapabilities(decoded, modelId);
    return capabilities?.input;
  } on Object {
    return null;
  }
}

/// The pre-flight capability gate for reference images (gh-1844): throws
/// a [MediaException] naming the slot/model and its declared/discovered
/// modalities when the endpoint is KNOWN not to accept images. Unknown
/// endpoints are the user's explicit configuration — the provider's own
/// error surfaces (documented in `docs/media-models.md`).
void ensureImageInputSupported({
  required String slot,
  required String modelId,
  required List<String>? inputModalities,
}) {
  if (inputModalities == null || inputModalities.contains('image')) return;
  throw MediaException(
    'the $slot endpoint (model "$modelId") does not accept image input '
    '(declared input modalities: ${inputModalities.join(', ')}). Remove '
    'the images argument for a text-only call, or point the slot at a '
    'model with image input.',
  );
}
