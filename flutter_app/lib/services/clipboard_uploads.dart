// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart'
    show
        FaChatUploadFile,
        FaClipboardUnsupportedException,
        mimeTypeForUploadName;
import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

import 'clipboard_files.dart';

/// The storable flavor priority of the composer's smart paste (issue
/// #1979 AC3): copied FILE references first, then anything image-shaped
/// the OS clipboard exposes, then the composer's own text rules. Audio /
/// video / pdf land in the first tier through their file references (Finder
/// / Explorer / Files copies, AirDrop-style shares) — raw binary flavors
/// beyond images have no cross-platform reader without the dependency chain
/// the owner rejected, so the native readers + [Pasteboard.image] are the
/// honest v1 surface.
///
/// Reads storable content off the system clipboard for the composer's smart
/// paste, richest flavor first:
///
/// 1. file references (our thin per-platform readers — iOS UIPasteboard,
///    Android ClipData + ContentResolver, macOS NSPasteboard, Windows
///    CF_HDROP via FFI, Linux text/uri-list);
/// 2. a raw image (Photos copies, screenshots) via `Pasteboard.image` —
///    staged under a synthesized `paste-<ts>.png` name.
///
/// An empty result is NOT always silence: when the clipboard visibly held
/// file-ish content that could not be staged, [FaClipboardUnsupportedException]
/// is thrown so the composer shows the explicit hint instead of falling
/// through to the text-paste rules. Missing image bytes and absent APIs are
/// plain empty results.
Future<List<FaChatUploadFile>> readClipboardUploads() async {
  final probe = await readClipboardFiles();
  if (probe.files.isNotEmpty) {
    return [
      for (final ref in probe.files)
        (
          name: ref.name,
          bytes: ref.bytes,
          mimeType: mimeTypeForUploadName(ref.name),
        ),
    ];
  }
  final image = await _readClipboardImage();
  if (image != null) return [image];
  if (probe.unsupported) {
    // The OS says the clipboard holds file-shaped data we could not stage
    // (oversized payload, unreadable provider) — never silence (AC8).
    throw const FaClipboardUnsupportedException();
  }
  return const [];
}

/// Reads a raw clipboard image via the `pasteboard` plugin (restored per
/// the owner's native-clipboard decision — no Rust, works on iOS/Android/
/// desktop/web). Staged under the issue-contract's synthesized paste name
/// (issue #465); PNG is what the plugin hands back for bitmap content.
Future<FaChatUploadFile?> _readClipboardImage() async {
  Uint8List? bytes;
  try {
    bytes = await Pasteboard.image;
  } on Object {
    // No plugin, no image, or a platform channel failure — fall through to
    // the text rules.
    return null;
  }
  if (bytes == null || bytes.isEmpty) return null;
  final name = 'paste-${DateTime.now().millisecondsSinceEpoch}.png';
  return (name: name, bytes: bytes, mimeType: mimeTypeForUploadName(name));
}
