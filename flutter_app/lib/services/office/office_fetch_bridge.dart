// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:http/http.dart' as http;

import 'office_fetch_bridge_stub.dart'
    if (dart.library.js_interop) 'office_fetch_bridge_web.dart';

/// Installs the SW fetch-bridge transport for the embedded office pane
/// (issue #470), or null outside the office build.
///
/// The pane (fa1.dev framed inside the Outlook tab) is page-context JS: its
/// provider fetches die on CORS because providers send no ACAO headers. When
/// this extension is installed, its content script
/// (`browser_ext/content/embed_relay.js`) carries pane HTTP across to the
/// service worker, which fetches CORS-free under `host_permissions`. Plain
/// web and the side panel (extension origin, already CORS-free) return null
/// and keep their direct transports — the bridge is additive and
/// context-gated (AC6). Even inside the pane, a missing relay (extension not
/// installed) degrades to the direct transport at the first request.
http.Client Function()? installOfficeHttpBridge() =>
    installOfficeHttpBridgeImpl();

/// The named failure when the pane can reach neither the extension bridge
/// nor the local fa hub (issue #633): it says what to do, in host order,
/// instead of surfacing the browser's raw network phrase ("Load failed").
const String officeRelayDownError =
    'provider unreachable from the add-in — relay not connected. '
    'Outlook desktop: start the fa CLI/app (fa hub serve) on this Mac — '
    'or use Outlook web. Outlook web: install the fa browser extension.';

/// The base URL of the local fa hub relay mount (issue #402 fabric): the
/// desktop taskpane (WKWebView — no extension exists there) proxies its
/// provider HTTP through `POST {base}/relay`. Mutable for tests.
// ponytail: well-known 8787 only; make it configurable when a second hub
// port exists to point at.
String officeHubRelayBase = 'http://127.0.0.1:8787';

/// True when an err-frame text means the BRIDGE transport itself died (an
/// MV3 service-worker restart mid-handshake, the extension context
/// invalidated by an update) — distinct from an upstream provider failure.
/// These are the errors a transparent retry with a fresh handshake answers
/// (issue #633 E1).
bool bridgeTransportDead(String error) {
  final e = error.toLowerCase();
  return e.contains('bridge port closed') ||
      e.contains('message port closed') ||
      e.contains('extension context invalidated');
}
