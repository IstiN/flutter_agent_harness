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

/// Maximum total bytes accepted in one upload batch: 25 MB.
///
/// The whole sandbox FS is snapshotted into IndexedDB as base64-in-JSON on
/// every change; the cap keeps snapshots (and the structured-clone payload)
/// comfortably inside browser quotas.
const int kMaxUploadBatchBytes = 25 * 1024 * 1024;

/// Returns an error message when [files] exceed [maxBytes] in total, else
/// `null`. Checked before anything is written so an oversized batch never
/// lands partially.
String? uploadBatchSizeError(
  List<UploadFile> files, {
  int maxBytes = kMaxUploadBatchBytes,
}) {
  var total = 0;
  for (final file in files) {
    total += file.bytes.length;
    if (total > maxBytes) {
      return 'Upload is too large: ${_formatMb(total)} exceeds the '
          '${_formatMb(maxBytes)} per-batch limit.';
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
