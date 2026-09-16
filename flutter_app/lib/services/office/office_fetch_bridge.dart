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
