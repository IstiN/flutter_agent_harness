// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:fa/apps/unpacked_loader.dart';

/// Browser [FolderPicker] (gh-1616): clicks a hidden
/// `<input type="file" webkitdirectory multiple>` — Chrome's "Load
/// unpacked" folder dialog — and reads every chosen file into memory.
///
/// The pick is an UPLOAD, not a mount: bytes are snapshotted at pick time
/// (the ticket's core-tier persistence contract — the env copy is the
/// widget, folder edits need an explicit re-load), and every file carries
/// its `webkitRelativePath` so the loader can strip the picked folder's
/// own name.
final class WebFolderPicker implements FolderPicker {
  @override
  Future<List<UnpackedPickedFile>> pickFolder() async {
    final input = html.FileUploadInputElement()
      ..multiple = true
      // webkitdirectory turns the file dialog into a folder dialog (the
      // attribute every Chromium build honors; the unprefixed `directory`
      // is the legacy alias some wrappers probe for).
      ..setAttribute('webkitdirectory', '')
      ..setAttribute('directory', '');
    // Listen before clicking so no event can slip through. Cancelling the
    // dialog fires `cancel` (not `change`) on the input — without the
    // race below a cancelled pick would hang the caller forever (the same
    // shape the upload picker solves; dart:html has no typed onCancel).
    final selection = Completer<bool>();
    final subscriptions = <StreamSubscription<Object?>>[
      input.onChange.listen((_) => selection.complete(true)),
      const html.EventStreamProvider<html.Event>(
        'cancel',
      ).forTarget(input).listen((_) => selection.complete(false)),
    ];
    input.click();
    final hasSelection = await selection.future;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (!hasSelection) return const [];

    final picked = <UnpackedPickedFile>[];
    for (final file in input.files ?? const <html.File>[]) {
      // webkitRelativePath is the picked folder's name + the path inside
      // it (per spec; a plain non-directory pick reports the empty string
      // — treat empty as absent and use the bare file name).
      final relative = file.relativePath;
      picked.add(
        UnpackedPickedFile(
          name: relative != null && relative.isNotEmpty ? relative : file.name,
          bytes: await readFileFully(file),
        ),
      );
    }
    return picked;
  }

  /// Reads [file] fully into memory; rejects when the read fails so the
  /// caller surfaces the error instead of hanging silently (E1 — a
  /// vanished folder is an honest error, never a hang).
  static Future<Uint8List> readFileFully(html.File file) {
    final completer = Completer<Uint8List>();
    final reader = html.FileReader();
    reader.onLoad.first.then((_) {
      try {
        // Since the SDK unified FileReader.result across the web
        // compilers, readAsArrayBuffer hands back a Uint8List view;
        // older SDKs returned the raw ByteBuffer. Accept both — and
        // never leave the completer hanging on a surprise (the same
        // contract as the upload picker's reader).
        completer.complete(switch (reader.result) {
          final Uint8List bytes => bytes,
          final ByteBuffer buffer => buffer.asUint8List(),
          final other => throw StateError(
            'Could not read ${file.name}: unexpected result type '
            '${other.runtimeType}',
          ),
        });
      } on Object catch (e) {
        completer.completeError(e);
      }
    });
    reader.onError.first.then((_) {
      completer.completeError(StateError('Could not read ${file.name}'));
    });
    reader.readAsArrayBuffer(file);
    return completer.future;
  }
}

/// Factory selected by the conditional import at the call site.
FolderPicker? createPlatformFolderPicker() => WebFolderPicker();
