// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:js_interop';

import 'package:fa/sandbox/fs_persistence.dart';

@JS()
external JSBoolean get _fahFsGetAllDefined;

@JS('__fahFsGetAll')
external JSPromise<JSObject?> _fahFsGetAllJs();

@JS('__fahFsSet')
external JSPromise _fahFsSetJs(JSObject items);

@JS('__fahFsRemove')
external JSPromise _fahFsRemoveJs(JSArray keys);

/// IndexedDB-backed [FsSnapshotStore] for the browser.
///
/// IndexedDB is used instead of localStorage on purpose: records carry
/// arbitrary uploaded binaries (base64 inside the JSON envelope), and
/// localStorage is string-only, synchronous, and capped around 5 MB, while
/// IndexedDB stores large payloads asynchronously under the real per-origin
/// storage quota. Records are flat key→string pairs — the envelope under
/// one key, one record per session file (issue #237) — so the database
/// never grows unboundedly and one bad write costs one record.
///
/// The IndexedDB calls live in `web/fs_store.js`, referenced from
/// `web/index.html` like the other externalized scripts. The helper used
/// to be injected as an inline `<script>` (the same pattern
/// `WebInterpreters` uses for its CDN runners), but MV3 extension pages
/// forbid inline code in their CSP, which turned every save into a console
/// error in the panel.
final class IdbFsSnapshotStore implements FsSnapshotStore {
  static bool _scriptChecked = false;

  static void _ensureScript() {
    if (_scriptChecked) return;
    // The helper ships as web/fs_store.js. Injecting it as an inline
    // <script> violates the MV3 extension CSP (extension_pages forbids
    // inline code), so the panel build needs the file, not an injection.
    _scriptChecked = _fahFsGetAllDefined.toDart;
    if (!_scriptChecked) {
      throw StateError(
        'fs_store.js is not loaded: add <script src="fs_store.js">'
        ' to index.html',
      );
    }
  }

  @override
  Future<Map<String, String>> load() async {
    _ensureScript();
    final result = await _fahFsGetAllJs().toDart;
    if (result == null) return {};
    final dartified = result.dartify() as Map<Object?, Object?>;
    return {
      for (final entry in dartified.entries) '${entry.key}': '${entry.value}',
    };
  }

  @override
  Future<void> save(Map<String, String> records) async {
    _ensureScript();
    await _fahFsSetJs(records.jsify() as JSObject).toDart;
  }

  @override
  Future<void> remove(Iterable<String> keys) async {
    _ensureScript();
    await _fahFsRemoveJs([for (final key in keys) key.toJS].toJS).toDart;
  }
}

/// Factory selected by the conditional import in `env_factory_stub.dart`.
FsSnapshotStore createFsSnapshotStore() => IdbFsSnapshotStore();
