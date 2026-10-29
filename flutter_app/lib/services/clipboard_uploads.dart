// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatUploadFile,
        FaClipboardUnsupportedException,
        mimeTypeForUploadName;
import 'package:flutter/foundation.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// The storable single-file clipboard flavors the smart paste walks, in the
/// issue's priority order (files > audio/video > image; issue #1979 AC3).
/// The extension determines the fallback `paste-<ts>.<ext>` name and, with
/// it, the MIME ([mimeTypeForUploadName]).
const List<(FileFormat, String)> _kPasteFileFormats = [
  // Audio: voice memos, copied mp3/m4a files without a file reference.
  (Formats.mp3, 'mp3'),
  (Formats.m4a, 'm4a'),
  (Formats.wav, 'wav'),
  (Formats.flac, 'flac'),
  (Formats.aac, 'aac'),
  (Formats.opus, 'opus'),
  (Formats.oga, 'oga'),
  // Video.
  (Formats.mp4, 'mp4'),
  (Formats.mov, 'mov'),
  (Formats.m4v, 'm4v'),
  (Formats.avi, 'avi'),
  (Formats.webm, 'webm'),
  (Formats.mkv, 'mkv'),
  (Formats.mpeg, 'mpeg'),
  (Formats.wmv, 'wmv'),
  // Documents that travel as raw flavors (not file references).
  (Formats.pdf, 'pdf'),
  // Images last: raw copies from Photos/Preview/screenshots.
  (Formats.png, 'png'),
  (Formats.jpeg, 'jpg'),
  (Formats.gif, 'gif'),
  (Formats.webp, 'webp'),
  (Formats.bmp, 'bmp'),
  (Formats.tiff, 'tiff'),
  (Formats.heic, 'heic'),
  (Formats.heif, 'heif'),
];

/// Reads storable files off the system clipboard for the composer's smart
/// paste (issue #1979 AC3/AC4), richest flavor first:
///
/// 1. copied file references (Finder/Explorer/Files "Copy") — every item
///    with a `file://` URI, read through [XFile];
/// 2. raw audio/video/pdf/image flavors (Photos copies, screenshots,
///    Acrobat PDF copies) — first matching flavor in [_kPasteFileFormats];
/// 3. otherwise nothing — the caller falls back to the text-paste rules.
///
/// An empty-but-not-clipboard clipboard (flavors exist, nothing storable,
/// no plain text) throws [FaClipboardUnsupportedException] so the composer
/// can hint instead of staying silent. [source] injects a reader in tests;
/// null probes [SystemClipboard.instance] (null → no clipboard API).
Future<List<FaChatUploadFile>> readClipboardUploads({
  ClipboardReader? source,
}) async {
  final ClipboardReader reader;
  if (source != null) {
    reader = source;
  } else {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return const [];
    reader = await clipboard.read();
  }

  // 1. File references — one clipboard item per copied file.
  final files = <FaChatUploadFile>[];
  for (final item in reader.items) {
    final Uri? uri;
    try {
      uri = await item.readValue(Formats.fileUri);
    } on Object {
      continue;
    }
    if (uri == null || !uri.isScheme('file')) continue;
    final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (name == null || name.isEmpty) continue;
    try {
      // cross_file has no XFile.fromUri; toFilePath() is dart:core, so this
      // compiles on web too (web clipboards carry no file URIs anyway).
      files.add((
        name: name,
        bytes: await XFile(uri.toFilePath()).readAsBytes(),
        mimeType: mimeTypeForUploadName(name),
      ));
    } on Object {
      // An unreadable reference (file moved/deleted) — skip it; the rest
      // of the batch still stages.
    }
  }
  if (files.isNotEmpty) return files;

  // 2. Raw rich flavors — first available wins.
  for (final (format, extension) in _kPasteFileFormats) {
    if (!reader.canProvide(format)) continue;
    final read = await _readFormatFile(reader, format);
    if (read == null) continue;
    final (bytes, fileName) = read;
    final name = fileName != null && fileName.isNotEmpty
        ? fileName
        : 'paste-${DateTime.now().millisecondsSinceEpoch}.$extension';
    return [(name: name, bytes: bytes, mimeType: mimeTypeForUploadName(name))];
  }

  // 3. Nothing storable. A non-empty clipboard without plain text means
  // the flavors are unsupported here — never silence (AC3).
  if (reader.platformFormats.isNotEmpty) {
    String? text;
    try {
      text = await reader.readValue(Formats.plainText);
    } on Object {
      // No text readable either — the throw below reports it.
    }
    if (text == null || text.isEmpty) {
      throw const FaClipboardUnsupportedException();
    }
  }
  return const [];
}

/// Reads one file-format payload off [reader]; null when the flavor turns
/// out not to be deliverable ([canProvide] is optimistic per the API docs,
/// and extraction can time out or fail). Failures here are not fatal — the
/// flavor walk continues, and the caller decides between text fallback and
/// the unsupported hint.
Future<(Uint8List, String?)?> _readFormatFile(
  ClipboardDataReader reader,
  FileFormat format,
) async {
  final done = Completer<(Uint8List, String?)?>();
  final progress = reader.getFile(format, (file) async {
    try {
      done.complete((await file.readAll(), file.fileName));
    } on Object catch (e) {
      done.completeError(e);
    }
  }, onError: (Object error) => done.completeError(error));
  if (progress == null) return null;
  try {
    // A paste must never hang on a stuck flavor (virtual iCloud files,
    // wedged providers) — give up quickly and let the walk continue.
    return await done.future.timeout(const Duration(seconds: 5));
  } on Object {
    return null;
  }
}
