// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'clipboard_files.dart';

/// Web stub for the native clipboard-file readers: a browser page cannot
/// read OS clipboard file payloads (only image/text flavors through the
/// async Clipboard API), so this is an honest empty.
FaClipboardFilesProbe readClipboardFilesWin32() =>
    (files: const <FaClipboardFileRef>[], unsupported: false);

FaClipboardFilesProbe readClipboardFilesUriList() =>
    (files: const <FaClipboardFileRef>[], unsupported: false);
