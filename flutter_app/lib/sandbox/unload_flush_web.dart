// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:js_interop';

import 'package:fa/sandbox/persistent_web_env.dart';

@JS('window.addEventListener')
external void _addWindowListener(String type, JSFunction listener);

@JS('document.addEventListener')
external void _addDocumentListener(String type, JSFunction listener);

@JS('document.visibilityState')
external String get _visibilityState;

@JS('console.warn')
external void _consoleWarn(String message);

/// Binds [PersistentWebExecutionEnv.onPageUnload] to the browser's
/// page-unload signals: `beforeunload` (tab/panel close, reload) and
/// `visibilitychange` → `hidden` (the extension side panel hides without
/// a full unload, and mobile browsers fire it instead of `beforeunload`).
///
/// The flush is best-effort: the browser does not await asynchronous work
/// from these handlers, but IndexedDB writes issued here routinely land
/// before the page is torn down — and with atomic snapshots a landed save
/// is always a consistent one. A save that still fails (quota) keeps the
/// env dirty and surfaces a console warning so the loss is diagnosable.
void bindUnloadFlush(PersistentWebExecutionEnv env) {
  void flush() {
    unawaited(
      env.onPageUnload().then((_) {
        if (env.hasPendingChanges) {
          _consoleWarn(
            '[fah] filesystem snapshot could not be saved before unload '
            '(storage quota?) — recent changes may be lost',
          );
        }
      }),
    );
  }

  _addWindowListener('beforeunload', ((JSAny? _) => flush()).toJS);
  _addDocumentListener('visibilitychange', ((JSAny? _) {
    if (_visibilityState == 'hidden') flush();
  }).toJS);
}
