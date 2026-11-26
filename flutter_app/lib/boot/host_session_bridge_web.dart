// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web bridge: the same-origin `localStorage` key the signed-in host page
/// writes before navigating to the agent shell (issue #2391). Read-only —
/// Fa never writes the bridge key anywhere.
///
/// `dart:html` matches the legacy popup receiver (`auth_loopback_web.dart`);
/// the package:web migration of that file covers this one too.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
library;

import 'dart:html' as html;

import 'host_session_bridge.dart';

/// The platform [HostSessionBridge]: browser localStorage, same origin.
HostSessionBridge platformHostSessionBridge = _WebBridge();

final class _WebBridge implements HostSessionBridge {
  @override
  String? read(String key) {
    try {
      return html.window.localStorage[key];
    } on Object {
      // Blocked/unavailable storage is "no session" (E7), never an error.
      return null;
    }
  }
}
