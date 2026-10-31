/// Inline-image pipeline for the `read` tool — thin private aliases over the
/// shared pipeline in `image_pipeline.dart` (gh-1985 C3 split the part-file
/// implementation out so `inspect_image` drives the SAME settings ladder;
/// the `read`-side call sites below keep their names and shapes unchanged).
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// Image handling for the read tool (aliases over src/tools/image_pipeline.dart)
// ---------------------------------------------------------------------------

/// Maximum width/height for inline images (pi's `maxWidth`/`maxHeight`).
const _defaultImageMaxDimension = defaultImageMaxDimension;

/// Base64 payload budget for inline images (pi's `DEFAULT_MAX_BYTES`).
const int _defaultImageMaxBase64Bytes = defaultImageMaxBase64Bytes;

const _supportedImageFormats = supportedImageFormats;

/// The pipeline result type (moved to [InlineImageResult] in
/// `image_pipeline.dart`); the part-tree call sites keep the private alias.
typedef _InlineImageResult = InlineImageResult;

_InlineImageResult _processImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxDimension = _defaultImageMaxDimension,
  int maxBase64Bytes = _defaultImageMaxBase64Bytes,
}) => processImage(
  bytes,
  format,
  maxDimension: maxDimension,
  maxBase64Bytes: maxBase64Bytes,
);

ImageFormat? _detectImageFormat(Uint8List bytes) => detectImageFormat(bytes);
