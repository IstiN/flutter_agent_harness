/// Inline-image processing pipeline (pi's `utils/image-process.ts` port):
/// format normalization, EXIF baking, and the PNG-then-JPEG byte-budget
/// shrink ladder. Split out of the `builtin_tools` part tree (gh-1985 C3)
/// so the `inspect_image` tool shares ONE pipeline with the `read` tool —
/// the same settings ladder, the same resize semantics, no drift.
///
/// Pure functions over `package:image`; no agent dependencies.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart';

import 'media_reference_images.dart';

/// Maximum width/height for inline images (pi's `maxWidth`/`maxHeight`).
const defaultImageMaxDimension = 2000;

/// Base64 payload budget for inline images: 4.5MB of base64 (== `4.5 * 1024 *
/// 1024`), providing headroom below Anthropic's 5MB inline limit (pi's
/// `DEFAULT_MAX_BYTES`).
const int defaultImageMaxBase64Bytes = 4718592;

/// JPEG quality ladder tried after PNG at each size step (pi's
/// `qualitySteps` with the default `jpegQuality` 80).
const imageJpegQualitySteps = [80, 85, 70, 55, 40];

const supportedImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
  ImageFormat.bmp,
};

/// Formats providers accept inline; other decodable formats (BMP) are
/// converted first (pi's `normalizeSupportedImageMimeType`).
const inlineImageFormats = {
  ImageFormat.png,
  ImageFormat.jpg,
  ImageFormat.gif,
  ImageFormat.webp,
};

/// Whether [format] rides provider requests inline as-is (no conversion).
bool isInlineImageFormat(ImageFormat format) =>
    inlineImageFormats.contains(format);

String? mimeTypeForImageFormat(ImageFormat format) {
  return switch (format) {
    ImageFormat.png => defaultImageMimeType,
    ImageFormat.jpg => 'image/jpeg',
    ImageFormat.gif => 'image/gif',
    ImageFormat.webp => 'image/webp',
    ImageFormat.bmp => 'image/bmp',
    _ => null,
  };
}

/// Encoded size of [bytes] as base64 text (pi compares the UTF-8 byte length
/// of the base64 string, which equals its character length).
int base64Length(Uint8List bytes) => ((bytes.length + 2) ~/ 3) * 4;

/// The outcome of the inline-image pipeline ([processImage] /
/// [resizeInlineImage] / [keepOriginalImage]): the base64 payload to send,
/// the ORIGINAL dimensions, and the dimensions it is actually displayed at.
final class InlineImageResult {
  const InlineImageResult({
    required this.mimeType,
    required this.base64,
    required this.width,
    required this.height,
    required this.resized,
    required this.outputWidth,
    required this.outputHeight,
    this.convertedFrom,
  });

  /// MIME type of the payload ([base64] carries).
  final String mimeType;

  /// Base64 payload.
  final String base64;

  /// ORIGINAL dimensions (before any resize/conversion).
  final int width;
  final int height;

  /// Whether the payload differs from the original bytes (resized or
  /// re-encoded).
  final bool resized;

  /// Dimensions the payload is displayed at.
  final int outputWidth;
  final int outputHeight;

  /// Source mime when a non-inline format was converted (e.g. BMP → PNG).
  final String? convertedFrom;
}

/// Normalizes [bytes] (non-inline formats decode and convert to PNG; EXIF
/// orientation is baked in) and fits them within the dimension and byte
/// limits (pi's `processImage`).
InlineImageResult processImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxDimension = defaultImageMaxDimension,
  int maxBase64Bytes = defaultImageMaxBase64Bytes,
}) {
  var inputBytes = bytes;
  var inputFormat = format;
  String? convertedFrom;
  if (!inlineImageFormats.contains(format)) {
    final source = decodeImageOrThrow(bytes);
    inputBytes = Uint8List.fromList(encodePng(bakeOrientation(source)));
    inputFormat = ImageFormat.png;
    convertedFrom = mimeTypeForImageFormat(format);
  }
  return resizeInlineImage(
    inputBytes,
    inputFormat,
    convertedFrom: convertedFrom,
    maxDimension: maxDimension,
    maxBase64Bytes: maxBase64Bytes,
  );
}

/// The `resize: "original"` path (gh-1985 AC6): keeps the ORIGINAL bytes
/// untouched when they fit [maxBase64Bytes] and the format rides provider
/// requests inline; otherwise shrinks MINIMALLY from the original
/// dimensions (EXIF baked, aspect preserved — no max-dimension clamp) until
/// the payload fits, so a keep-original call over budget degrades by the
/// smallest step instead of the full settings ladder. The caller surfaces
/// the applied size ([InlineImageResult.outputWidth]/[outputHeight]) in its
/// note when [InlineImageResult.resized] is true.
InlineImageResult keepOriginalImage(
  Uint8List bytes,
  ImageFormat format, {
  int maxBase64Bytes = defaultImageMaxBase64Bytes,
}) {
  final inline = inlineImageFormats.contains(format);
  if (inline && base64Length(bytes) < maxBase64Bytes) {
    final decoded = decodeImageOrThrow(bytes);
    final image = bakeExifOrientation(decoded);
    return InlineImageResult(
      mimeType: mimeTypeForImageFormat(format) ?? defaultImageMimeType,
      base64: base64Encode(bytes),
      width: image.width,
      height: image.height,
      resized: false,
      outputWidth: image.width,
      outputHeight: image.height,
    );
  }
  // Over budget (or a non-inline format): bake EXIF, then shrink from the
  // ORIGINAL dimensions — the minimal degradation of the keep-original
  // contract — until the byte budget fits.
  final image = bakeExifOrientation(decodeImageOrThrow(bytes));
  var currentWidth = image.width;
  var currentHeight = image.height;
  while (true) {
    final fitted = fitImageAtSize(
      image,
      image.width,
      image.height,
      currentWidth,
      currentHeight,
      maxBase64Bytes,
      null,
    );
    if (fitted != null) return fitted;
    final (nextWidth, nextHeight) = nextShrinkStep(currentWidth, currentHeight);
    if (shrinkStepStalls(currentWidth, currentHeight, nextWidth, nextHeight)) {
      throw StateError(
        'Could not resize image below the inline image size limit',
      );
    }
    currentWidth = nextWidth;
    currentHeight = nextHeight;
  }
}

/// Fits an inline-format image within the dimension and base64 byte limits.
///
/// Ported from pi's `resizeImageInProcess` (`utils/image-resize-core.ts`):
/// EXIF orientation is baked before measuring; images already within ALL
/// limits pass through with their ORIGINAL bytes untouched; otherwise each
/// size step tries PNG, then JPEG at decreasing quality
/// ([imageJpegQualitySteps]), shrinking dimensions by 0.75 until a candidate
/// fits the byte budget.
InlineImageResult resizeInlineImage(
  Uint8List bytes,
  ImageFormat format, {
  required String? convertedFrom,
  required int maxDimension,
  required int maxBase64Bytes,
}) {
  final decoded = decodeImageOrThrow(bytes);
  // Bake EXIF orientation before measuring/resizing so the model sees the
  // image as displayed (pi's `applyExifOrientation`).
  final image = bakeExifOrientation(decoded);
  final width = image.width;
  final height = image.height;

  // Pass-through: within the dimension AND byte limits, keep the original
  // bytes untouched (no re-encode).
  if (width <= maxDimension &&
      height <= maxDimension &&
      base64Length(bytes) < maxBase64Bytes) {
    return InlineImageResult(
      mimeType: mimeTypeForImageFormat(format) ?? defaultImageMimeType,
      base64: base64Encode(bytes),
      width: width,
      height: height,
      resized: false,
      outputWidth: width,
      outputHeight: height,
      convertedFrom: convertedFrom,
    );
  }

  final (:targetWidth, :targetHeight) = clampToMaxDimension(
    width,
    height,
    maxDimension,
  );

  final fitted = shrinkInlineImageToFit(
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

/// The shrink loop of [resizeInlineImage]: tries [fitImageAtSize] at the
/// current size, then shrinks dimensions by 0.75 and retries, until a
/// candidate fits the byte budget. Returns null when the shrink stalls (see
/// [shrinkStepStalls]) so the caller can fail with pi's error.
InlineImageResult? shrinkInlineImageToFit(
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
    final fitted = fitImageAtSize(
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
/// limits — even a maximal source clamps to [defaultImageMaxDimension] and
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
Image decodeImageOrThrow(Uint8List bytes) {
  final decoded = decodeImage(bytes);
  if (decoded == null) {
    throw StateError('Could not decode image');
  }
  return decoded;
}

/// Decodes [bytes] and bakes EXIF orientation in one step (the stitch path's
/// tile decoder — gh-1985 "HEIC inputs to stitch decode via the existing
/// pipeline first").
Image decodeImageOriented(Uint8List bytes) =>
    bakeExifOrientation(decodeImageOrThrow(bytes));

/// Bakes EXIF orientation into the pixels when the tag says the stored image
/// is rotated/flipped (pi's `applyExifOrientation`); otherwise returns
/// [decoded] untouched.
Image bakeExifOrientation(Image decoded) {
  return decoded.exif.imageIfd.hasOrientation &&
          decoded.exif.imageIfd.orientation != 1
      ? bakeOrientation(decoded)
      : decoded;
}

/// The initial resize target: the original dimensions when already within
/// [maxDimension], else the aspect-preserving clamp to it (pi's
/// `targetWidth`/`targetHeight`).
({int targetWidth, int targetHeight}) clampToMaxDimension(
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
/// ([imageJpegQualitySteps]); returns null when no candidate fits the byte
/// budget, so the caller shrinks and retries.
InlineImageResult? fitImageAtSize(
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
  final png = Uint8List.fromList(encodePng(candidate));
  if (base64Length(png) < maxBase64Bytes) {
    return InlineImageResult(
      mimeType: defaultImageMimeType,
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
  for (final quality in imageJpegQualitySteps) {
    final jpeg = Uint8List.fromList(encodeJpg(candidate, quality: quality));
    if (base64Length(jpeg) < maxBase64Bytes) {
      jpegBase64 = base64Encode(jpeg);
      break;
    }
  }
  if (jpegBase64 != null) {
    return InlineImageResult(
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

/// Detects the [ImageFormat] of [bytes] via the image library's data
/// probe; null for undetectable payloads.
ImageFormat? detectImageFormat(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  try {
    return findFormatForData(bytes);
  } on Object {
    return null;
  }
}
