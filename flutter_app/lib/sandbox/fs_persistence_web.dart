// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';

import 'fs_persistence.dart';

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
/// The IndexedDB calls run in an injected helper script (the same pattern
/// `WebInterpreters` uses for its CDN runners): `dart:indexed_db` only
/// exists for the web compilers, so calling it directly would break host
/// analysis of this file.
final class IdbFsSnapshotStore implements FsSnapshotStore {
  static bool _scriptInjected = false;

  static void _ensureScript() {
    if (_scriptInjected ||
        html.document.getElementById('fah-fs-store') != null) {
      _scriptInjected = true;
      return;
    }
    final script = html.ScriptElement()
      ..id = 'fah-fs-store'
      ..type = 'text/javascript'
      ..text = _storeSource;
    html.document.head!.append(script);
    _scriptInjected = true;
  }

  /// Installs `window.__fahFsLoad()` / `window.__fahFsSave(snapshot)`,
  /// promise-returning IndexedDB accessors over a single `snapshots` object
  /// store. The open promise is cached (and reset on failure, so a later
  /// retry can recover).
  static const _storeSource = r'''
window.__fahFsOpen = function() {
  if (!window.__fahFsDbPromise) {
    window.__fahFsDbPromise = new Promise(function(resolve, reject) {
      var req = indexedDB.open('fah_web_fs', 1);
      req.onupgradeneeded = function() {
        var db = req.result;
        if (!db.objectStoreNames.contains('snapshots')) {
          db.createObjectStore('snapshots');
        }
      };
      req.onsuccess = function() { resolve(req.result); };
      req.onerror = function() {
        window.__fahFsDbPromise = null;
        reject(req.error);
      };
    });
  }
  return window.__fahFsDbPromise;
};
window.__fahFsLoad = function() {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var req = db.transaction('snapshots', 'readonly')
        .objectStore('snapshots').get('sandbox');
      req.onsuccess = function() {
        resolve(req.result === undefined ? null : req.result);
      };
      req.onerror = function() { reject(req.error); };
    });
  });
};
window.__fahFsSave = function(snapshot) {
  return window.__fahFsOpen().then(function(db) {
    return new Promise(function(resolve, reject) {
      var txn = db.transaction('snapshots', 'readwrite');
      txn.objectStore('snapshots').put(snapshot, 'sandbox');
      txn.oncomplete = function() { resolve(null); };
      txn.onerror = function() { reject(txn.error); };
    });
  });
};
''';

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
