// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:fa/sandbox/fs_persistence.dart';

@JS()
external JSBoolean get _fahFsLoadDefined;

@JS('__fahFsLoad')
external JSPromise _fahFsLoadJs();

@JS('__fahFsSave')
external JSPromise _fahFsSaveJs(String snapshot);

/// IndexedDB-backed [FsSnapshotStore] for the browser.
///
/// IndexedDB is used instead of localStorage on purpose: snapshots carry
/// arbitrary uploaded binaries (base64 inside the JSON envelope), and
/// localStorage is string-only, synchronous, and capped around 5 MB, while
/// IndexedDB stores large payloads asynchronously under the real per-origin
/// storage quota. The whole sandbox tree lives behind one key; each save
/// replaces it, so the database never grows unboundedly across saves.
///
/// The IndexedDB calls live in `web/fs_store.js`, referenced from
/// `web/index.html` like the other externalized scripts. The helper used
/// to be injected as an inline `<script>` (the same pattern `WebInterpreters`
/// uses for its CDN runners), but MV3 extension pages forbid inline code in
/// their CSP, which turned every save into a console error in the panel.
final class IdbFsSnapshotStore implements FsSnapshotStore {
  static bool _scriptChecked = false;

  static void _ensureScript() {
    if (_scriptChecked) return;
    // The helper ships as web/fs_store.js. Injecting it as an inline
    // <script> violates the MV3 extension CSP (extension_pages forbids
    // inline code), so the panel build needs the file, not an injection.
    _scriptChecked = _fahFsLoadDefined.toDart;
    if (!_scriptChecked) {
      throw StateError(
        'fs_store.js is not loaded: add <script src="fs_store.js">'
        ' to index.html',
      );
    }
  }

  @override
  Future<String?> load() async {
    _ensureScript();
    final result = await _fahFsLoadJs().toDart;
    return result == null ? null : (result as JSString).toDart;
  }

  @override
  Future<void> save(String snapshot) async {
    _ensureScript();
    await _fahFsSaveJs(snapshot).toDart;
  }
}

/// Factory selected by the conditional import in `env_factory_stub.dart`.
FsSnapshotStore createFsSnapshotStore() => IdbFsSnapshotStore();
