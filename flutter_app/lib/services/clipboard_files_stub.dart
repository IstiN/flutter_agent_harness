// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'clipboard_files.dart';

/// Web stub for the native clipboard-file readers: a browser page cannot
/// read OS clipboard file payloads (only image/text flavors through the
/// async Clipboard API), so this is an honest empty. Signatures mirror the
/// io impls (Future-returning) — the reader map in clipboard_files.dart
/// assigns both behind the same conditional import.
Future<FaClipboardFilesProbe> readClipboardFilesWin32() async =>
    (files: const <FaClipboardFileRef>[], unsupported: false);

Future<FaClipboardFilesProbe> readClipboardFilesUriList() async =>
    (files: const <FaClipboardFileRef>[], unsupported: false);
