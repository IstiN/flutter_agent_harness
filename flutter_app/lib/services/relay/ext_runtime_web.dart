// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The web-side `chrome.runtime` binding: extension detection via
/// `chrome.runtime?.id` and a [UiPortChannel] over `chrome.runtime.connect`.
///
/// Wire shape: protocol envelopes travel as JSON strings — the SW side's
/// port adapter speaks the same shape, so both ends share one encoding.
/// A dropped port (MV3 service worker update/crash) completes the message
/// stream, which the relay transport treats as the reconnect signal.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:fa_browser_agent/fa_browser_agent.dart';

@JS('chrome.runtime.id')
external JSString? get _runtimeId;

@JS('chrome.runtime.connect')
external _JsPort? _connect();

extension type _JsPort._(JSObject _) implements JSObject {
  external void postMessage(JSAny? message);
  external _JsEvent get onMessage;
  external _JsEvent get onDisconnect;
}

extension type _JsEvent._(JSObject _) implements JSObject {
  external void addListener(JSFunction listener);
}

/// Whether this build runs inside the browser extension panel: only an
/// extension page has a non-null `chrome.runtime.id`.
bool isExtensionHost() => _runtimeId != null;

/// Opens a `chrome.runtime` port channel, or null when unavailable.
UiPortChannel? createPortChannel() {
  if (!isExtensionHost()) return null;
  final port = _connect();
  if (port == null) return null;
  return _RuntimePortChannel(port);
}

final class _RuntimePortChannel implements UiPortChannel {
  _RuntimePortChannel(this._port) {
    _port.onMessage.addListener(
      ((JSAny? message) {
        if (closed) return;
        final decoded = _decode(message);
        if (decoded != null) _inbound.add(decoded);
      }).toJS,
    );
    _port.onDisconnect.addListener(
      (() {
        if (!closed) _inbound.close();
      }).toJS,
    );
  }

  final _JsPort _port;
  final _inbound = StreamController<Map<String, dynamic>>.broadcast();
  var closed = false;

  /// One JSON envelope per port message; undecodable frames are dropped —
  /// the transport's protocol decoder never sees garbage and the SW-side
  /// `malformed` error path stays the single source of protocol failures.
  static Map<String, dynamic>? _decode(JSAny? raw) {
    try {
      final text = (raw as JSString).toDart;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // fallthrough: not a JSON string envelope
    }
    return null;
  }

  @override
  void send(Map<String, dynamic> json) {
    if (closed) return;
    _port.postMessage(jsonEncode(json).toJS);
  }

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  @override
  void close() {
    if (closed) return;
    closed = true;
    _inbound.close();
  }

  @override
  bool get isClosed => closed;
}
