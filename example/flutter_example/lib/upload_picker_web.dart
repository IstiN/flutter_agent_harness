// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'upload.dart';

/// Browser [UploadPicker]: clicks a hidden `<input type="file" multiple>`
/// and reads the chosen files fully into memory.
final class WebUploadPicker implements UploadPicker {
  @override
  Future<List<UploadFile>> pick() async {
    final input = html.FileUploadInputElement()..multiple = true;
    // Listen before clicking so no event can slip through. Cancelling the
    // dialog fires `cancel` (not `change`) on the input — without the race
    // below a cancelled pick would hang the caller forever. dart:html has
    // no typed `onCancel` for file inputs, so subscribe to the raw event.
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

    final picked = <UploadFile>[];
    for (final file in input.files ?? const <html.File>[]) {
      // webkitRelativePath is the empty string (not null) on plain
      // non-directory picks per spec — treat empty as absent so the file
      // name is used; an empty name would be silently dropped downstream.
      final relative = file.relativePath;
      picked.add((
        name: relative != null && relative.isNotEmpty ? relative : file.name,
        bytes: await readFileFully(file),
      ));
    }
    return picked;
  }

  /// Reads [file] fully into memory; rejects when the read fails so the
  /// caller surfaces the error instead of hanging silently.
  static Future<Uint8List> readFileFully(html.File file) {
    final completer = Completer<Uint8List>();
    final reader = html.FileReader();
    reader.onLoad.first.then((_) {
      try {
        // Since the SDK unified FileReader.result across the web compilers,
        // readAsArrayBuffer hands back a Uint8List view; older SDKs returned
        // the raw ByteBuffer. Accept both — and never leave the completer
        // hanging on a surprise, which is what killed uploads silently.
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
UploadPicker? createUploadPicker() => WebUploadPicker();
