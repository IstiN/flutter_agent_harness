// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:win32/win32.dart';

import 'clipboard_files.dart';

/// The largest file the Windows/Linux clipboard readers stage (headroom over
/// the service's 20 MB upload cap; bigger pasteboard payloads are skipped
/// and surface as the unsupported hint downstream).
const int _kMaxClipboardFileBytes = 32 * 1024 * 1024;

/// Windows: read `CF_HDROP` off the clipboard through win32 FFI — no plugin,
/// no Rust (the owner's #1979 decision). Explorer copies arrive as a
/// DROPFILES blob: a header, then the file paths (wide or narrow chars)
/// terminated by a double null. The FFI body is deliberately a chain of
/// tiny steps: the CRAP ratchet measures this file on Linux CI where only
/// the `Platform.isWindows` guard line can execute, so every Windows-only
/// unit must stay at CC ≤ 3 (0%-covered worst case) while the pure parse
/// and staging units carry their own tests.
Future<FaClipboardFilesProbe> readClipboardFilesWin32() async {
  // FFI guard: the dispatch never routes here off-Windows, but tests and
  // accidental calls must not poke user32 on other platforms.
  if (!Platform.isWindows) {
    return faEmptyClipboardProbe();
  }
  return _readWin32Drop();
}

Future<FaClipboardFilesProbe> _readWin32Drop() async {
  if (!OpenClipboard(null).value) {
    // Clipboard busy or inaccessible — nothing readable this round.
    return faEmptyClipboardProbe();
  }
  try {
    return await _openClipboardFiles();
  } finally {
    CloseClipboard();
  }
}

Future<FaClipboardFilesProbe> _openClipboardFiles() async {
  final dataHandle = GetClipboardData(CF_HDROP);
  if (dataHandle.value == nullptr) {
    return faEmptyClipboardProbe();
  }
  final hglobal = HGLOBAL(dataHandle.value);
  final locked = GlobalLock(hglobal).value;
  if (locked == nullptr) {
    return faEmptyClipboardProbe();
  }
  try {
    return await _probeFromPaths(
      _decodeDropPaths(
        locked.cast<Uint8>().asTypedList(GlobalSize(hglobal).value),
      ),
    );
  } finally {
    GlobalUnlock(hglobal);
  }
}

/// Decodes a DROPFILES blob into the file paths it carries. Pure data
/// transformation — unit-tested with synthetic blobs (wide and narrow).
List<String> _decodeDropPaths(Uint8List blob) {
  if (blob.length < 20) return const [];
  final data = ByteData.sublistView(blob);
  // DROPFILES { DWORD pFiles; POINT pt; BOOL fWide; }
  final listOffset = data.getUint32(0, Endian.little);
  final wide = data.getInt32(16, Endian.little) != 0;
  final paths = <String>[];
  final codeUnits = <int>[];
  var i = listOffset;
  while (i < blob.length) {
    final unit = wide ? data.getUint16(i, Endian.little) : blob[i];
    if (unit == 0) {
      // An empty segment is the list's double-null terminator.
      if (codeUnits.isEmpty) break;
      paths.add(String.fromCharCodes(codeUnits));
      codeUnits.clear();
    } else {
      codeUnits.add(unit);
    }
    i += wide ? 2 : 1;
  }
  // Malformed blob without a terminator: keep the trailing path anyway.
  if (codeUnits.isNotEmpty) paths.add(String.fromCharCodes(codeUnits));
  return paths;
}

/// Stages decoded clipboard paths: readable files become refs, failures
/// surface as the unsupported flag when nothing else staged. Pure
/// filesystem — unit-tested with temp files.
Future<FaClipboardFilesProbe> _probeFromPaths(List<String> paths) async {
  final files = <FaClipboardFileRef>[];
  var unsupported = false;
  for (final path in paths) {
    final ref = await _readFile(path);
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
  final listing = await _clipboardUriListing(runProcess);
  if (listing == null) {
    return faEmptyClipboardProbe();
  }
  return _stageUriList(listing);
}

/// Asks the desktop clipboard CLIs for the raw `text/uri-list`; null when
/// neither is installed or both fail.
Future<String?> _clipboardUriListing(FaProcessRunner runProcess) async {
  const attempts = [
    ('xclip', <String>['-selection', 'clipboard', '-t', 'text/uri-list', '-o']),
    ('wl-paste', <String>['-t', 'text/uri-list']),
  ];
  for (final (executable, arguments) in attempts) {
    try {
      final result = await runProcess(executable, arguments);
      if (result.exitCode == 0) {
        final out = (result.stdout as String?)?.trim();
        if (out != null && out.isNotEmpty) return out;
      }
    } on Object {
      // CLI missing (not installed) — try the next one.
    }
  }
  return null;
}

/// Stages a raw uri-list body: `file://` entries become refs, anything
/// else (or unreadable) counts toward the unsupported flag when nothing
/// else staged.
Future<FaClipboardFilesProbe> _stageUriList(String listing) async {
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

/// Test seams: the CRAP ratchet's coverage comes from these units' tests
/// (the win32 FFI calls themselves need a Windows device run).
@visibleForTesting
List<String> decodeDropPathsForTest(Uint8List blob) => _decodeDropPaths(blob);

@visibleForTesting
Future<FaClipboardFilesProbe> probePathsForTest(List<String> paths) =>
    _probeFromPaths(paths);
