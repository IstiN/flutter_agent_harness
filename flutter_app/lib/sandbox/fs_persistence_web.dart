// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:fa/sandbox/fs_persistence.dart';

@JS()
external JSBoolean get _fahFsLoadDefined;

@JS('__fahFsLoadAll')
external JSPromise _fahFsLoadAllJs();

@JS('__fahFsSave')
external JSPromise _fahFsSaveJs(String key, String value);

@JS('__fahFsRemove')
external JSPromise _fahFsRemoveJs(String keysJson);

/// IndexedDB-backed [FsRecordStore] for the browser.
///
/// IndexedDB is used instead of localStorage on purpose: records carry
/// arbitrary uploaded binaries (base64 inside the JSON envelope), and
/// localStorage is string-only, synchronous, and capped around 5 MB, while
/// IndexedDB stores large payloads asynchronously under the real per-origin
/// storage quota. The store is a flat key→value surface (issue #237): the
/// versioned JSON envelope of the non-session tree lives under one key and
/// every session file is its own record, so an over-quota session write
/// fails alone and never takes unrelated saves (or other sessions) down
/// with it.
///
/// The IndexedDB calls live in `web/fs_store.js`, referenced from
/// `web/index.html` like the other externalized scripts. The helper used
/// to be injected as an inline `<script>` (the same pattern `WebInterpreters`
/// uses for its CDN runners), but MV3 extension pages forbid inline code in
/// their CSP, which turned every save into a console error in the panel.
final class IdbFsRecordStore implements FsRecordStore {
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
  Future<Map<String, String>> loadAll() async {
    _ensureScript();
    final result = await _fahFsLoadAllJs().toDart;
    if (result == null) return const {};
    final decoded = jsonDecode((result as JSString).toDart);
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        entry.key as String: entry.value as String,
    };
  }

  @override
  Future<void> save(String key, String value) async {
    _ensureScript();
    await _fahFsSaveJs(key, value).toDart;
  }

  @override
  Future<void> remove(List<String> keys) async {
    if (keys.isEmpty) return;
    _ensureScript();
    await _fahFsRemoveJs(jsonEncode(keys)).toDart;
  }
}

/// Factory selected by the conditional import in `env_factory_stub.dart`.
FsRecordStore createFsSnapshotStore() => IdbFsRecordStore();
