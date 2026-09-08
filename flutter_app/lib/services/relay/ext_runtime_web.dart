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
import 'dart:js_interop';

import 'package:fa_browser_agent/fa_browser_agent.dart';

/// Port name the SW's UI port server serves (`agent_main.dart` drops every
/// other port) — pinned across packages; agent_main owns the private twin.
const _uiPortName = 'fa-ui-v2';

/// `window.chrome` — undefined on Firefox/Safari and on Chrome pages where
/// the injection was disabled; present (but bare) on a normal Chrome page.
@JS('chrome')
external _JsChromeNs? get _chromeNs;

extension type _JsChromeNs._(JSObject _) implements JSObject {
  /// `chrome.runtime` — undefined OUTSIDE an extension context; deep-path
  /// bindings (`@JS('chrome.runtime.id')`) THROW on that missing segment,
  /// so every hop is bound separately and stepped through null-safely.
  external _JsRuntimeNs? get runtime;

  /// `chrome.tabs` — present on extension pages (no permission needed for
  /// [extOpenTab]); null elsewhere, stepped through null-safely.
  external _JsTabsNs? get tabs;
}

extension type _JsRuntimeNs._(JSObject _) implements JSObject {
  external JSString? get id;
}

extension type _JsTabsNs._(JSObject _) implements JSObject {
  /// MV3: `tabs.create` resolves a Promise of the created tab.
  external JSPromise<_JsTab?> create(_JsCreateProperties props);
}

extension type _JsCreateProperties._(JSObject _) implements JSObject {
  external _JsCreateProperties({String? url});
}

extension type _JsTab._(JSObject _) implements JSObject {
  external int? get id;
}

extension type _JsFetchResponse._(JSObject _) implements JSObject {
  external int get status;
  external JSPromise<JSString> text();
}

/// The page `fetch` — on an extension page with `<all_urls>` host
/// permissions this is the cookie-authenticated HTTP path (see
/// [extFetchString]).
@JS('fetch')
external JSPromise<_JsFetchResponse> _pageFetch(JSString url, JSObject init);

extension type _JsConnectInfo._(JSObject _) implements JSObject {
  external _JsConnectInfo({String? name});
}

/// `chrome.runtime.connect` — resolved through the stepped bindings above;
/// only called once [isExtensionHost] has proven both segments exist.
@JS('chrome.runtime.connect')
external _JsPort? _connect([_JsConnectInfo? connectInfo]);

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
bool isExtensionHost() => _chromeNs?.runtime?.id != null;

/// Opens [url] in a new browser tab. Extension pages only; false outside
/// an extension context. This is the sign-in surface: a NORMAL tab (IdPs
/// forbid framing their login pages) whose session lands in the shared
/// cookie jar.
Future<bool> extOpenTab(String url) async {
  final tabs = _chromeNs?.tabs;
  if (tabs == null) return false;
  final tab = await tabs.create(_JsCreateProperties(url: url)).toDart;
  return tab != null;
}

/// One cookie-authenticated HTTP GET from the extension page: MV3 +
/// `<all_urls>` host permissions mean no CORS, and `credentials: 'include'`
/// makes the browser attach the cookie jar (setting a `Cookie` header
/// itself is a forbidden-header no-op). Returns null outside an extension
/// context.
Future<({int status, String body})?> extFetchString(String url) async {
  if (!isExtensionHost()) return null;
  final init = ({'credentials': 'include'}).jsify() as JSObject;
  final response = await _pageFetch(url.toJS, init).toDart;
  final body = await response.text().toDart;
  return (status: response.status, body: body.toDart);
}

/// Opens a `chrome.runtime` port channel, or null when unavailable.
///
/// The port MUST be named `fa-ui-v2` — that is the name the SW's UI port
/// server (`agent_main.dart` `_uiPortName`) filters on; an unnamed port is
/// silently dropped by both SW listeners and the relay never answers.
UiPortChannel? createPortChannel() {
  if (!isExtensionHost()) return null;
  final port = _connect(_JsConnectInfo(name: _uiPortName));
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

  /// Structured-clone envelopes: the SW's port adapter dartifies incoming
  /// maps directly (no JSON round-trip), so this side must post maps too —
  /// a JSON *string* frame is silently skipped as protocol garbage by the
  /// SW. Non-map frames here are dropped the same way.
  static Map<String, dynamic>? _decode(JSAny? raw) {
    try {
      final decoded = raw?.dartify();
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // fallthrough: not a map envelope
    }
    return null;
  }

  @override
  void send(Map<String, dynamic> json) {
    if (closed) return;
    _port.postMessage(json.jsify());
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
