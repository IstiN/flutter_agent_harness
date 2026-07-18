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
    input.click();
    await input.onChange.first;
    final picked = <UploadFile>[];
    for (final file in input.files ?? const <html.File>[]) {
      picked.add((
        name: file.relativePath ?? file.name,
        bytes: await _readAll(file),
      ));
    }
    return picked;
  }

  Future<Uint8List> _readAll(html.File file) {
    final completer = Completer<Uint8List>();
    final reader = html.FileReader();
    reader.onLoad.first.then((_) {
      completer.complete((reader.result as ByteBuffer).asUint8List());
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
