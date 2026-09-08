// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web stub: no platform outside the browser can host a chrome
/// extension, so the probe is a constant false and no port channel is
/// ever created (the relay falls back to the local agent path).
library;

import 'package:fa_browser_agent/fa_browser_agent.dart';

/// Whether this build runs inside the browser extension panel.
bool isExtensionHost() => false;

/// Opens a `chrome.runtime` port channel, or null when unavailable.
UiPortChannel? createPortChannel() => null;

/// Opens [url] in a new browser tab — extension pages only; always false
/// on non-web platforms.
Future<bool> extOpenTab(String url) async => false;

/// One cookie-authenticated HTTP GET from the extension page — always
/// null on non-web platforms.
Future<({int status, String body})?> extFetchString(String url) async => null;
