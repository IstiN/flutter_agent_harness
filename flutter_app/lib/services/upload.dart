// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Upload helpers (name sanitizing, MIME guessing, batch size check) live
/// in the `fa_ui` package next to the shared chat composer; this shim keeps
/// the app's existing import path working. The [UploadPicker] interface and
/// its platform implementations stay here — the shared composer consumes
/// picking through the `FaChatHost` hooks instead.
library;

export 'package:fa_ui/fa_ui.dart'
    show
        UploadFile,
        kInlineImageMimeTypes,
        isInlineImageMimeType,
        mimeTypeForUploadName,
        kMaxUploadBatchBytes,
        uploadBatchSizeError,
        sanitizeUploadName;

import 'package:fa_ui/fa_ui.dart' show UploadFile;

/// Opens the platform file chooser for arbitrary files.
///
/// Implementations: `upload_picker_web.dart` (a hidden browser
/// `<input type="file" multiple>`), `upload_picker_stub.dart` (none — the
/// upload affordance hides itself when the factory returns `null`).
abstract interface class UploadPicker {
  /// Returns the chosen files; empty when the user cancels.
  Future<List<UploadFile>> pick();
}
