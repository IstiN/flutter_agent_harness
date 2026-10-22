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
