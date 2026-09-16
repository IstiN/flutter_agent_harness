// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:fa/sandbox/fs_persistence.dart';
import 'package:web/web.dart' as web;

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

  /// Loads the helper on demand. Every build's `index.html` ships the
  /// `<script src="fs_store.js">` tag, but a stale or hand-assembled bundle
  /// can miss it (issue #470: the embedded Outlook pane booted with no
  /// persistence at all). Instead of only throwing, inject the same-origin
  /// file — allowed by every CSP here ('self'), unlike the inline injection
  /// that MV3 extension pages forbid — and re-check once; throw only if the
  /// helper is still missing afterwards.
  static Future<void> _ensureScript() async {
    if (_scriptChecked) return;
    if (!_fahFsGetAllDefined.toDart) {
      await _injectFsStoreScript();
    }
    _scriptChecked = _fahFsGetAllDefined.toDart;
    if (!_scriptChecked) {
      throw StateError(
        'fs_store.js is not loaded: add <script src="fs_store.js">'
        ' to index.html',
      );
    }
  }

  /// Appends `<script src="fs_store.js">` and completes on load/error.
  static Future<void> _injectFsStoreScript() {
    final completer = Completer<void>();
    final script =
        web.document.createElement('script') as web.HTMLScriptElement;
    script.src = 'fs_store.js';
    script.onload = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    script.onerror = ((web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }).toJS;
    web.document.head?.appendChild(script);
    return completer.future;
  }

  @override
  Future<Map<String, String>> load() async {
    await _ensureScript();
    final result = await _fahFsGetAllJs().toDart;
    if (result == null) return {};
    final dartified = result.dartify() as Map<Object?, Object?>;
    return {
      for (final entry in dartified.entries) '${entry.key}': '${entry.value}',
    };
  }

  @override
  Future<void> save(Map<String, String> records) async {
    await _ensureScript();
    await _fahFsSetJs(records.jsify() as JSObject).toDart;
  }

  @override
  Future<void> remove(Iterable<String> keys) async {
    await _ensureScript();
    await _fahFsRemoveJs([for (final key in keys) key.toJS].toJS).toDart;
  }
}

/// Factory selected by the conditional import in `env_factory_stub.dart`.
FsSnapshotStore createFsSnapshotStore() => IdbFsSnapshotStore();
