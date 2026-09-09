// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web [DapHubService]: inside the browser extension the panel talks to
/// the service worker's real DAP client (`ExtensionDapHubService`); on a
/// plain web page there is no hub to reach, so the honest not-supported
/// stub stands.
library;

import 'dart:js_interop';

import 'dap_service.dart';
import 'dap_service_stub.dart';
import 'dap_service_web_core.dart';

/// Creates the platform [DapHubService] (web).
DapHubService createDapHubService() {
  final runtime = _chrome?.runtime;
  if (runtime?.id == null) return const UnsupportedDapHubService();
  return ExtensionDapHubService(
    sendMessage: _swSendMessage,
    storageGet: _swStorageGet,
  );
}

// -- chrome.* bindings (extension pages only; every hop stepped through
// null-safely because `chrome` exists but is bare on normal Chrome pages) --

@JS('chrome')
external _JsChromeNs? get _chrome;

extension type _JsChromeNs._(JSObject _) implements JSObject {
  external _JsRuntimeNs? get runtime;
  external _JsStorageNs? get storage;
}

extension type _JsRuntimeNs._(JSObject _) implements JSObject {
  external JSAny? get id;

  /// `chrome.runtime.sendMessage` — Promise of the handler's response.
  external JSPromise<JSAny?> sendMessage(JSAny? message);
}

extension type _JsStorageNs._(JSObject _) implements JSObject {
  external _JsStorageAreaNs? get local;
}

extension type _JsStorageAreaNs._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get(JSAny? keys);
}

Future<Object?> _swSendMessage(Map<String, Object?> message) async {
  final runtime = _chrome?.runtime;
  if (runtime == null) throw StateError('chrome.runtime is unavailable');
  final reply = await runtime.sendMessage(message.jsify()).toDart;
  return reply.dartify();
}

Future<Object?> _swStorageGet(String key) async {
  final local = _chrome?.storage?.local;
  if (local == null) throw StateError('chrome.storage.local is unavailable');
  final result = await local.get(key.toJS).toDart;
  return result.dartify();
}
