/// Inline-image pipeline for the `read` tool (pi's `utils/image-process.ts`): format normalization, EXIF baking, and the PNG-then-JPEG byte-budget shrink ladder ([_processImage], [_resizeInlineImage]). Split out of `builtin_tools.dart` to keep that file under the repo line gate; same library (a `part of`), so the privates stay visible.
part of 'builtin_tools.dart';

// ---------------------------------------------------------------------------
// Image handling for the read tool
// ---------------------------------------------------------------------------

/// Maximum width/height for inline images (pi's `maxWidth`/`maxHeight`).
const _defaultImageMaxDimension = 2000;

/// Base64 payload budget for inline images: 4.5MB of base64 (== `4.5 * 1024 *
/// 1024`), providing headroom below Anthropic's 5MB inline limit (pi's
/// `DEFAULT_MAX_BYTES`).
const _defaultImageMaxBase64Bytes = 4718592;

/// JPEG quality ladder tried after PNG at each size step (pi's `qualitySteps`
/// with the default `jpegQuality` 80).
const _imageJpegQualitySteps = [80, 85, 70, 55, 40];

const _supportedImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
  ImageFormat.bmp,
};

/// Formats providers accept inline; other decodable formats (BMP) are
/// converted first (pi's `normalizeSupportedImageMimeType`).
const _inlineImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
};

String? _mimeTypeForImageFormat(ImageFormat format) {
  return switch (format) {
    ImageFormat.png => 'image/png',
    ImageFormat.jpg => 'image/jpeg',
    ImageFormat.gif => 'image/gif',
    ImageFormat.webp => 'image/webp',
    ImageFormat.bmp => 'image/bmp',
    _ => null,
  };
}

/// Encoded size of [bytes] as base64 text (pi compares the UTF-8 byte length
/// of the base64 string, which equals its character length).
int _base64Length(Uint8List bytes) => ((bytes.length + 2) ~/ 3) * 4;

/// The outcome of the inline-image pipeline ([_processImage] /
/// [_resizeInlineImage]): the base64 payload to send, the ORIGINAL
/// dimensions, and the dimensions it is actually displayed at.
typedef _InlineImageResult = ({
  String mimeType,
  String base64,
  int width,
  int height,
  bool resized,
  int outputWidth,
  int outputHeight,
  String? convertedFrom,
});

_InlineImageResult _processImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxDimension = _defaultImageMaxDimension,
  int maxBase64Bytes = _defaultImageMaxBase64Bytes,
}) {
  // Normalize (pi's `normalizeImage`): formats providers do not accept inline
  // (BMP) decode and convert to PNG first; EXIF orientation is baked in.
  var inputBytes = bytes;
  var inputFormat = format;
  String? convertedFrom;
  if (!_inlineImageFormats.contains(format)) {
    final source = _decodeOrThrow(bytes);
    inputBytes = encodePng(bakeOrientation(source));
    inputFormat = ImageFormat.png;
    convertedFrom = _mimeTypeForImageFormat(format);
  }
  return _resizeInlineImage(
    inputBytes,
    inputFormat,
    convertedFrom: convertedFrom,
    maxDimension: maxDimension,
    maxBase64Bytes: maxBase64Bytes,
  );
}

/// Fits an inline-format image within the dimension and base64 byte limits.
///
/// Ported from pi's `resizeImageInProcess` (`utils/image-resize-core.ts`):
/// EXIF orientation is baked before measuring; images already within ALL
/// limits pass through with their ORIGINAL bytes untouched; otherwise each
/// size step tries PNG, then JPEG at decreasing quality
/// ([_imageJpegQualitySteps]), shrinking dimensions by 0.75 until a candidate
/// fits the byte budget.
_InlineImageResult _resizeInlineImage(
  Uint8List bytes,
  ImageFormat format, {
  required String? convertedFrom,
  required int maxDimension,
  required int maxBase64Bytes,
}) {
  final decoded = _decodeOrThrow(bytes);
  // Bake EXIF orientation before measuring/resizing so the model sees the
  // image as displayed (pi's `applyExifOrientation`).
  final image = _bakeExifOrientation(decoded);
  final width = image.width;
  final height = image.height;

  // Pass-through: within the dimension AND byte limits, keep the original
  // bytes untouched (no re-encode).
  if (width <= maxDimension &&
      height <= maxDimension &&
      _base64Length(bytes) < maxBase64Bytes) {
    return (
      mimeType: _mimeTypeForImageFormat(format) ?? 'image/png',
      base64: base64Encode(bytes),
      width: width,
      height: height,
      resized: false,
      outputWidth: width,
      outputHeight: height,
      convertedFrom: convertedFrom,
    );
  }

  final (:targetWidth, :targetHeight) = _clampToMaxDimension(
    width,
    height,
    maxDimension,
  );

  final fitted = _shrinkInlineImageToFit(
    image,
    width,
    height,
    targetWidth,
    targetHeight,
    maxBase64Bytes,
    convertedFrom,
  );
  if (fitted != null) return fitted;

  throw StateError('Could not resize image below the inline image size limit');
}

/// The shrink loop of [_resizeInlineImage]: tries [_fitImageAtSize] at the
/// current size, then shrinks dimensions by 0.75 and retries, until a
/// candidate fits the byte budget. Returns null when the shrink stalls (see
/// [shrinkStepStalls]) so the caller can fail with pi's error.
_InlineImageResult? _shrinkInlineImageToFit(
  Image image,
  int width,
  int height,
  int targetWidth,
  int targetHeight,
  int maxBase64Bytes,
  String? convertedFrom,
) {
  var currentWidth = targetWidth;
  var currentHeight = targetHeight;
  while (true) {
    final fitted = _fitImageAtSize(
      image,
      width,
      height,
      currentWidth,
      currentHeight,
      maxBase64Bytes,
      convertedFrom,
    );
    if (fitted != null) return fitted;

    final (nextWidth, nextHeight) = nextShrinkStep(currentWidth, currentHeight);
    if (shrinkStepStalls(currentWidth, currentHeight, nextWidth, nextHeight)) {
      return null;
    }
    currentWidth = nextWidth;
    currentHeight = nextHeight;
  }
}

/// One 0.75 shrink step of the inline-image shrink loop (a dimension already
/// at 1 stays there).
(int, int) nextShrinkStep(int width, int height) =>
    (width == 1 ? 1 : width * 3 ~/ 4, height == 1 ? 1 : height * 3 ~/ 4);

/// The shrink loop's safety valves: the step stalls at 1x1 or when the 0.75
/// shrink stops making progress. Unreachable via the public API with default
/// limits — even a maximal source clamps to [_defaultImageMaxDimension] and
/// fits the byte budget long before the step stalls.
bool shrinkStepStalls(
  int currentWidth,
  int currentHeight,
  int nextWidth,
  int nextHeight,
) {
  return (currentWidth == 1 && currentHeight == 1) ||
      (nextWidth == currentWidth && nextHeight == currentHeight);
}

/// Decodes [bytes], throwing when the image library cannot make sense of
/// them (a valid signature with a garbage payload).
Image _decodeOrThrow(Uint8List bytes) {
  final decoded = decodeImage(bytes);
  if (decoded == null) {
    throw StateError('Could not decode image');
  }
  return decoded;
}

/// Bakes EXIF orientation into the pixels when the tag says the stored image
/// is rotated/flipped (pi's `applyExifOrientation`); otherwise returns
/// [decoded] untouched.
Image _bakeExifOrientation(Image decoded) {
  return decoded.exif.imageIfd.hasOrientation &&
          decoded.exif.imageIfd.orientation != 1
      ? bakeOrientation(decoded)
      : decoded;
}

/// The initial resize target: the original dimensions when already within
/// [maxDimension], else the aspect-preserving clamp to it (pi's
/// `targetWidth`/`targetHeight`).
({int targetWidth, int targetHeight}) _clampToMaxDimension(
  int width,
  int height,
  int maxDimension,
) {
  var targetWidth = width;
  var targetHeight = height;
  if (width > maxDimension || height > maxDimension) {
    if (width >= height) {
      targetWidth = maxDimension;
      targetHeight = (height * maxDimension / width).round();
    } else {
      targetHeight = maxDimension;
      targetWidth = (width * maxDimension / height).round();
    }
  }
  return (targetWidth: targetWidth, targetHeight: targetHeight);
}

/// Tries one size step: PNG first, then JPEG at decreasing quality
/// ([_imageJpegQualitySteps]); returns null when no candidate fits the byte
/// budget, so the caller shrinks and retries.
_InlineImageResult? _fitImageAtSize(
  Image image,
  int width,
  int height,
  int currentWidth,
  int currentHeight,
  int maxBase64Bytes,
  String? convertedFrom,
) {
  final candidate = currentWidth == width && currentHeight == height
      ? image
      : copyResize(
          image,
          width: currentWidth,
          height: currentHeight,
          interpolation: Interpolation.cubic,
        );
  final png = encodePng(candidate);
  if (_base64Length(png) < maxBase64Bytes) {
    return (
      mimeType: 'image/png',
      base64: base64Encode(png),
      width: width,
      height: height,
      resized: true,
      outputWidth: currentWidth,
      outputHeight: currentHeight,
      convertedFrom: convertedFrom,
    );
  }
  String? jpegBase64;
  for (final quality in _imageJpegQualitySteps) {
    final jpeg = encodeJpg(candidate, quality: quality);
    if (_base64Length(jpeg) < maxBase64Bytes) {
      jpegBase64 = base64Encode(jpeg);
      break;
    }
  }
  if (jpegBase64 != null) {
    return (
      mimeType: 'image/jpeg',
      base64: jpegBase64,
      width: width,
      height: height,
      resized: true,
      outputWidth: currentWidth,
      outputHeight: currentHeight,
      convertedFrom: convertedFrom,
    );
  }
  return null;
}

ImageFormat? _detectImageFormat(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    return findFormatForData(bytes);
  } on Object {
    return null;
  }
}
