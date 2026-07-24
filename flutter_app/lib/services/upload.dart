// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

/// One file picked for upload into the sandbox filesystem. [name] is the
/// browser-provided name (or relative path); [bytes] is the full content.
typedef UploadFile = ({String name, Uint8List bytes});

/// Opens the platform file chooser for arbitrary files.
///
/// Implementations: `upload_picker_web.dart` (a hidden browser
/// `<input type="file" multiple>`), `upload_picker_stub.dart` (none — the
/// upload affordance hides itself when the factory returns `null`).
abstract interface class UploadPicker {
  /// Returns the chosen files; empty when the user cancels.
  Future<List<UploadFile>> pick();
}

/// The image MIME types that may be inlined as image content (chat
/// attachments for hosted vision providers, and the on-device
/// transformers.js vision path).
///
/// Deliberately an ALLOWLIST, not `mimeType.startsWith('image/')`: SVG is
/// markup (`image/svg+xml`), not a raster image — inlining it feeds
/// undecodable bytes to image decoders (and, on-device, to ONNX Runtime's
/// `RawImage`, which poisons the WebGPU session). Only formats every
/// consumer can actually decode qualify.
const kInlineImageMimeTypes = {
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
};

/// Whether [mimeType] is an inline-able raster image type (see
/// [kInlineImageMimeTypes]). SVG and any other `image/*` type are NOT —
/// they travel as plain file references.
bool isInlineImageMimeType(String mimeType) =>
    kInlineImageMimeTypes.contains(mimeType.toLowerCase());

/// Guesses a MIME type from a file [name]'s extension; anything
/// unrecognized (including `.svg`) is `application/octet-stream`, which
/// never inlines as an image.
String mimeTypeForUploadName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'application/octet-stream';
}

/// Maximum total bytes accepted in one upload batch: 25 MB.
///
/// The whole sandbox FS is snapshotted into IndexedDB as base64-in-JSON on
/// every change; the cap keeps snapshots (and the structured-clone payload)
/// comfortably inside browser quotas.
const int kMaxUploadBatchBytes = 25 * 1024 * 1024;

/// Returns an error message when [files] exceed [maxBytes] in total, else
/// `null`. Checked before anything is written so an oversized batch never
/// lands partially.
///
/// The message is user-facing (callers show it in a SnackBar); pass
/// [message] to produce a localized copy — e.g.
/// `(total, max) => context.l10n.uploadTooLarge(max, total)` — the default
/// keeps the English text for callers that cannot localize yet.
String? uploadBatchSizeError(
  List<UploadFile> files, {
  int maxBytes = kMaxUploadBatchBytes,
  String Function(String total, String max)? message,
}) {
  var total = 0;
  for (final file in files) {
    total += file.bytes.length;
    if (total > maxBytes) {
      final totalMb = _formatMb(total);
      final maxMb = _formatMb(maxBytes);
      return message?.call(totalMb, maxMb) ??
          'Upload is too large: $totalMb exceeds the $maxMb per-batch limit.';
    }
  }
  return null;
}

String _formatMb(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Strips path separators and `.`/`..` segments from a picked file [name]
/// (some browsers send a `webkitRelativePath`), so the upload stays inside
/// the target directory. Returns the cleaned relative path — possibly with
/// subdirectories — or an empty string when nothing usable is left.
String sanitizeUploadName(String name) {
  final segments = name
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  return segments.join('/');
}
