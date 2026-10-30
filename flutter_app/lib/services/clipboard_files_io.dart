// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data' show ByteData, Endian;

import 'package:win32/win32.dart';

import 'clipboard_files.dart';

/// The largest file the Windows/Linux clipboard readers stage (headroom over
/// the service's 20 MB upload cap; bigger pasteboard payloads are skipped
/// and surface as the unsupported hint downstream).
const int _kMaxClipboardFileBytes = 32 * 1024 * 1024;

/// Windows: read `CF_HDROP` off the clipboard through win32 FFI — no plugin,
/// no Rust (the owner's #1979 decision). Explorer copies arrive as a
/// DROPFILES blob: a header, then the file paths (wide or narrow chars)
/// terminated by a double null.
Future<FaClipboardFilesProbe> readClipboardFilesWin32() async {
  // FFI guard: the dispatch never routes here off-Windows, but tests and
  // accidental calls must not poke user32 on other platforms.
  if (!Platform.isWindows) {
    return (files: const <FaClipboardFileRef>[], unsupported: false);
  }
  if (!OpenClipboard(null).value) {
    // Clipboard busy or inaccessible — nothing readable this round.
    return (files: const <FaClipboardFileRef>[], unsupported: false);
  }
  try {
    final dataHandle = GetClipboardData(CF_HDROP);
    if (dataHandle.value == nullptr) return _emptyProbe();
    final hglobal = HGLOBAL(dataHandle.value);
    final locked = GlobalLock(hglobal).value;
    if (locked == nullptr) return _emptyProbe();
    try {
      final size = GlobalSize(hglobal).value;
      final bytes = locked.cast<Uint8>().asTypedList(size);
      final data = ByteData.sublistView(bytes);
      // DROPFILES { DWORD pFiles; POINT pt; BOOL fWide; }
      final listOffset = data.getUint32(0, Endian.little);
      final wide = data.getInt32(16, Endian.little) != 0;
      final files = <FaClipboardFileRef>[];
      var unsupported = false;
      var start = listOffset;
      var i = listOffset;
      while (i < size) {
        final unit = wide ? data.getUint16(i, Endian.little) : bytes[i];
        if (unit == 0) {
          final path = wide
              ? String.fromCharCodes(
                  bytes
                      .sublist(start, i)
                      .buffer
                      .asUint16List(0, (i - start) ~/ 2),
                )
              : String.fromCharCodes(bytes.sublist(start, i));
          if (path.isEmpty) break; // the list's final double terminator
          final ref = await _readFile(path);
          if (ref == null) {
            unsupported = true;
          } else {
            files.add(ref);
          }
          start = i + (wide ? 2 : 1);
        }
        i += wide ? 2 : 1;
      }
      if (files.isEmpty && unsupported) {
        return (files: const <FaClipboardFileRef>[], unsupported: true);
      }
      return (files: files, unsupported: false);
    } finally {
      GlobalUnlock(hglobal);
    }
  } finally {
    CloseClipboard();
  }
}

FaClipboardFilesProbe _emptyProbe() =>
    (files: const <FaClipboardFileRef>[], unsupported: false);

Future<FaClipboardFileRef?> _readFile(String path) async {
  try {
    final file = File(path);
    if (await file.length() > _kMaxClipboardFileBytes) return null;
    return FaClipboardFileRef(
      name: path.split(Platform.pathSeparator).last,
      bytes: await file.readAsBytes(),
    );
  } on Object {
    return null;
  }
}

/// The injected process runner seam (tests fake xclip/wl-paste).
typedef FaProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Linux: read `text/uri-list` off the CLIPBOARD selection — the format
/// file managers and most apps put copied files under. xclip covers X11,
/// wl-paste covers Wayland; both are the standard desktop clipboard CLIs.
Future<FaClipboardFilesProbe> readClipboardFilesUriList({
  FaProcessRunner runProcess = Process.run,
}) async {
  const attempts = [
    ('xclip', <String>['-selection', 'clipboard', '-t', 'text/uri-list', '-o']),
    ('wl-paste', <String>['-t', 'text/uri-list']),
  ];
  String? listing;
  for (final (executable, arguments) in attempts) {
    try {
      final result = await runProcess(executable, arguments);
      if (result.exitCode == 0) {
        final out = (result.stdout as String?)?.trim();
        if (out != null && out.isNotEmpty) {
          listing = out;
          break;
        }
      }
    } on Object {
      // CLI missing (not installed) — try the next one.
    }
  }
  if (listing == null) {
    return (files: const <FaClipboardFileRef>[], unsupported: false);
  }
  final files = <FaClipboardFileRef>[];
  var unsupported = false;
  for (final line in listing.split('\n')) {
    final uri = line.trim();
    if (uri.isEmpty || uri.startsWith('#')) continue;
    final ref = await _readUri(uri);
    if (ref == null) {
      unsupported = true;
    } else {
      files.add(ref);
    }
  }
  if (files.isEmpty && unsupported) {
    return (files: const <FaClipboardFileRef>[], unsupported: true);
  }
  return (files: files, unsupported: false);
}

Future<FaClipboardFileRef?> _readUri(String raw) async {
  try {
    final uri = Uri.parse(raw);
    if (!uri.isScheme('file')) return null;
    return await _readFile(uri.toFilePath());
  } on Object {
    return null;
  }
}
