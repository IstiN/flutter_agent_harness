// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/upload.dart';
import 'package:file_selector/file_selector.dart';

/// Native [UploadPicker] (issue #1979 AC1): the system file chooser on
/// every platform — NSOpenPanel on macOS, the Windows/Linux dialogs, the
/// iOS document picker, Android SAF — any file type, multi-select. Files
/// are read fully into memory; the shared staging cap is checked
/// downstream (the composer and the file browser both run
/// `uploadBatchSizeError` before anything stages).
final class IoUploadPicker implements UploadPicker {
  @override
  Future<List<UploadFile>> pick() async {
    // No type groups = every file type selectable.
    final files = await openFiles();
    if (files.isEmpty) return const []; // user cancelled the dialog.
    return [
      for (final file in files)
        (name: file.name, bytes: await file.readAsBytes()),
    ];
  }
}

/// Factory selected by the conditional import at the call site.
UploadPicker? createUploadPicker() => IoUploadPicker();
