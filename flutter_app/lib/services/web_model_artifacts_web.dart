// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The OPFS-backed [GemmaWebArtifactStore] (gh-2004): enumerates the
/// storage root's top-level entries and removes the gema stack's cached
/// model artifacts. The old flutter_gemma plugin streamed the `.litertlm`
/// weights straight into OPFS (`WebStorageMode.streaming`) and kept its
/// registry beside them — this store deletes the same shapes.
library;

import 'dart:js_interop';

import 'package:fa/services/leftover_model_cleanup.dart';
import 'package:web/web.dart' as web;

extension type _JSAsyncIterator<T extends JSAny>._(JSObject _)
    implements JSObject {
  external JSPromise<_JSIteratorResult<T>> next();
}

/// One `next()` step of the OPFS async iterator (`{done, value}`).
extension type _JSIteratorResult<T extends JSAny>._(JSObject _)
    implements JSObject {
  external JSBoolean? get done;
  external T? get value;
}

extension _DirIteration on web.FileSystemDirectoryHandle {
  /// The `values()` async iterator (not part of package:web's typed API —
  /// called through an interop extension member).
  external _JSAsyncIterator<web.FileSystemHandle> values();
}

/// Creates the platform store (web build).
GemmaWebArtifactStore createGemmaWebArtifactStore() => _OpfsArtifactStore();

final class _OpfsArtifactStore implements GemmaWebArtifactStore {
  @override
  Future<List<GemmaArtifactEntry>> listRoot() async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final iterator = root.values();
    final entries = <GemmaArtifactEntry>[];
    while (true) {
      final step = await iterator.next().toDart;
      if (step == null || (step.done?.toDart ?? true)) break;
      final handle = step.value;
      if (handle == null) break;
      entries.add(
        GemmaArtifactEntry(
          name: handle.name,
          directory: handle.kind == 'directory',
        ),
      );
    }
    return entries;
  }

  @override
  Future<void> remove(String name, {bool directory = false}) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    await root
        .removeEntry(
          name,
          web.FileSystemRemoveOptions(recursive: directory),
        )
        .toDart;
  }
}
