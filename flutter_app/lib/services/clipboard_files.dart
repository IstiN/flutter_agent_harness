// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'clipboard_files_io.dart'
    if (dart.library.js_interop) 'clipboard_files_stub.dart'
    as impl;

/// One file read off the system clipboard by the native/OS-level clipboard
/// readers ([readClipboardFiles]) — a copied file reference (Finder /
/// Explorer / Files "Copy"), an iOS Files-app drag-out, an Android content
/// URI, or a Linux URI-list entry — with its bytes already read.
class FaClipboardFileRef {
  const FaClipboardFileRef({required this.name, required this.bytes});

  /// The file name to stage under (last path segment / content-resolver
  /// display name / URI last segment).
  final String name;

  /// The file's bytes, read by the platform reader.
  final Uint8List bytes;
}

/// The result of the platform clipboard-file probe: the readable files plus
/// whether the clipboard visibly held file-ish content that could NOT be
/// staged (drives the composer's "unsupported paste" hint instead of
/// silence — issue #1979 AC3/AC8).
typedef FaClipboardFilesProbe = ({
  List<FaClipboardFileRef> files,
  bool unsupported,
});

/// The method channel the thin per-platform readers answer
/// (iOS/macOS: Runner AppDelegate; Android: MainActivity).
const MethodChannel _channel = MethodChannel('fa/clipboard_files');

/// Empty result helpers shared by the platform readers (a single shape so
/// every reader's degrade paths stay identical).
FaClipboardFilesProbe faEmptyClipboardProbe() =>
    (files: const <FaClipboardFileRef>[], unsupported: false);

/// Per-platform clipboard-file readers. A map, not a switch: the CRAP
/// ratchet runs on Linux CI where only the Linux arm can ever execute, and
/// a partially-covered branch ladder cannot stay under the 12.0 ratchet
/// (issue #1979 — the #558 pattern).
final Map<TargetPlatform, Future<FaClipboardFilesProbe> Function()> _readers = {
  TargetPlatform.iOS: _readViaChannel,
  TargetPlatform.android: _readViaChannel,
  TargetPlatform.macOS: _readViaChannel,
  TargetPlatform.windows: impl.readClipboardFilesWin32,
  TargetPlatform.linux: impl.readClipboardFilesUriList,
};

/// Reads FILE content off the system clipboard through our own thin
/// per-platform readers (owner decision on #1979: no super_clipboard / no
/// Rust / no vendoring):
///
/// - iOS — `UIPasteboard.general.items`, UTI `public.file-url`, bytes read
///   through the staged security-scoped URL;
/// - Android — `ClipData` item URIs read via `ContentResolver.openInputStream`
///   (no storage permission needed for pasted URIs);
/// - macOS — `NSPasteboard` file URLs (`public.file-url` /
///   `NSFilenamesPboardType`);
/// - Windows — `CF_HDROP` via win32 FFI (pure Dart, package:win32);
/// - Linux — `text/uri-list` off the CLIPBOARD selection (xclip / wl-paste);
/// - web — no OS clipboard file access; returns empty.
///
/// Every failure mode (no handler, read error, oversized file) degrades to
/// an empty list or the [FaClipboardFilesProbe.unsupported] flag — this
/// function never throws.
Future<FaClipboardFilesProbe> readClipboardFiles() async {
  if (kIsWeb) return faEmptyClipboardProbe();
  final reader =
      _readers[defaultTargetPlatform] ??
      ((() async => faEmptyClipboardProbe()));
  return reader();
}

Future<FaClipboardFilesProbe> _readViaChannel() async {
  try {
    // The standard codec decodes nested maps/lists as dynamic containers —
    // pattern the shapes, never pin the reified type args.
    final answer = await _channel.invokeMethod<Object?>('readClipboardFiles');
    final rawFiles = (answer as Map?)?['files'];
    final files = <FaClipboardFileRef>[];
    if (rawFiles is List) {
      for (final raw in rawFiles) {
        if (raw is! Map) continue;
        final name = raw['name'];
        final bytes = raw['bytes'];
        if (name is String && name.isNotEmpty && bytes is Uint8List) {
          files.add(FaClipboardFileRef(name: name, bytes: bytes));
        }
      }
    }
    final unsupported = answer is Map ? answer['unsupported'] == true : false;
    return (files: files, unsupported: unsupported);
  } on MissingPluginException {
    // No native handler (e.g. the desktop app predates the channel):
    // behave as if the clipboard holds no files.
    return faEmptyClipboardProbe();
  } on Object {
    // Channel-level failure: not a stageable-content signal — silent empty.
    return faEmptyClipboardProbe();
  }
}

/// Visible for the service tests; the composer only ever goes through
/// [readClipboardFiles].
@visibleForTesting
Future<FaClipboardFilesProbe> readClipboardFilesViaChannelForTest() =>
    _readViaChannel();
