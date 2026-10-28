/// Image-count overflow detection via provider-specific error-message
/// regexes (issue #1750) — the image-count twin of `overflow.dart`'s
/// context-overflow table.
///
/// The outbound request carried more unique images than the target model
/// accepts; the provider refuses with a recognizable error and the agent
/// loop degrades by re-sending with fewer images instead of killing the
/// turn. Only shapes actually observed from a provider live here —
/// invented limits and speculative regexes rot; add a pattern when a
/// refusal string is pinned from the wild.
library;

/// The parsed image-cap refusal: the model the provider named and the
/// cap it announced.
final class ImageCapRefusal {
  const ImageCapRefusal({required this.modelId, required this.learnedCap});

  /// The model id from the refusal text (`maximum allowed for model
  /// gemini-4-argon is 10` → `gemini-4-argon`).
  final String modelId;

  /// The cap the provider announced. May be garbage (< 1) — the caller
  /// guards before latching/re-sending (edge E3).
  final int learnedCap;
}

/// The refusal patterns, one per provider shape (the `overflow.dart`
/// convention — a flat list, first match wins):
///
/// - Google/Gemini: `400: too many images: maximum allowed for model
///   gemini-4-argon is 10, got 15`
final _imageCapPatterns = [
  RegExp(
    r'\btoo many images\b.*?\bmaximum allowed for model (.+?) is (\d+)',
    caseSensitive: false,
  ),
];

/// Whether [errorMessage] is an image-count cap refusal, and — when it
/// is — the `(modelId, learnedCap)` parsed from it (issue #1750).
///
/// Returns null for everything else (near-misses like `maximum allowed
/// for model X is 10` WITHOUT `too many images`, auth 400s, rate limits,
/// context overflows). An unparseable cap digit cannot match (the group
/// is `\d+`); a matched-but-degenerate cap (`is 0`) still classifies —
/// the refusal IS the family — and the caller's degenerate-cap guard
/// skips the re-send (edge E3).
ImageCapRefusal? classifyImageCapError(String? errorMessage) {
  if (errorMessage == null) return null;
  for (final pattern in _imageCapPatterns) {
    final match = pattern.firstMatch(errorMessage);
    if (match == null) continue;
    return ImageCapRefusal(
      modelId: match.group(1)!,
      learnedCap: int.parse(match.group(2)!),
    );
  }
  return null;
}

/// gh-1934: payload-size (413-class) refusal patterns — the recovery
/// ladder's trigger family, the image-byte twin of the image-count table
/// above. Deliberately conservative shapes only: a false positive burns
/// two bounded recovery passes on an unrelated failure, so a bare `413`
/// digit never matches without HTTP/error-code context (a number inside
/// prose — `line 413`, `41305 tokens` — is not a refusal).
final _payloadTooLargePatterns = [
  // The original repro's shape (GitHub Copilot API): `413: Request
  // Entity Too Large`.
  RegExp(r'request entity too large', caseSensitive: false),
  RegExp(r'payload too large', caseSensitive: false),
  RegExp(r'request body too large', caseSensitive: false),
  RegExp(r'request too large', caseSensitive: false),
  // Anthropic HTTP 413 body.
  RegExp(r'request_too_large', caseSensitive: false),
  // A message LEADING with the status code (`413: …`, `413 (no body)` —
  // the Cerebras shape).
  RegExp(r'^\s*413\s*[:(]'),
  // HTTP-context spellings: `HTTP 413`, `HTTP/1.1 413`, `status code: 413`,
  // `{"error":{"code":413}}`.
  RegExp(r'\bhttps?/?\d*\.?\d*\s*413\b', caseSensitive: false),
  RegExp(r'\bstatus( code)?\s*[:=]\s*"?413\b', caseSensitive: false),
  RegExp(r'\bcode"\]?\s*[:=]\s*413\b', caseSensitive: false),
];

/// gh-1934: rate-limit/throttling wordings that own a message — the same
/// guard set `overflow.dart` applies, mirrored locally (the file stays
/// import-free). A `413` digit inside one never classifies.
final _rateLimitGuardPatterns = [
  RegExp(r'^(Throttling error|Service unavailable):', caseSensitive: false),
  RegExp(r'rate limit', caseSensitive: false),
  RegExp(r'too many requests', caseSensitive: false),
];

/// gh-1934: whether [errorMessage] is a payload-size (413-class) refusal —
/// the provider rejected the REQUEST SIZE (not the token count and not the
/// image count; those classify in `overflow.dart` /
/// [classifyImageCapError]). The 413 recovery ladder's trigger; rate-limit
/// and throttling wordings own the message (same guard as the tables
/// above), so a `413` digit inside one never classifies.
bool isPayloadTooLargeError(String? errorMessage) {
  if (errorMessage == null || errorMessage.isEmpty) return false;
  final isNonOverflow = _rateLimitGuardPatterns.any(
    (pattern) => pattern.hasMatch(errorMessage),
  );
  if (isNonOverflow) return false;
  return _payloadTooLargePatterns.any(
    (pattern) => pattern.hasMatch(errorMessage),
  );
}
