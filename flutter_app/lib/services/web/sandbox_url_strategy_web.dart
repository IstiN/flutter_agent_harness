// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation: probe the History API and swap in a no-op URL
/// strategy when the host sandbox took it away (issue #202 — OWA taskpane
/// iframes ship a `history` stub without `replaceState`; the engine's
/// default deep-link sync then throws `q.replaceState is not a function`
/// mid-boot, killing the chain before Office.onReady and graying the pane).
library;

import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:fa/services/relay/relay_probe.dart' show kFaBuildHost;

/// [ui_web.urlStrategy] installed by [installSandboxSafeUrlStrategy].
///
/// "No-op" means: the BROWSER's History API is never touched (it throws
/// in the sandboxed iframe). The engine's single-entry origin
/// bookkeeping still runs on top of the strategy and requires
/// `getState()` to return what the last `replaceState`/`pushState`
/// wrote (it null-asserts the restored entry state mid-boot), so this
/// strategy keeps that entry in a field instead. Never `const` for the
/// same reason — the store is per-instance state.
class NoOpUrlStrategy implements ui_web.UrlStrategy {
  Object? _state;

  @override
  String getPath() => '/';

  @override
  Object? getState() => _state;

  @override
  String prepareExternalUrl(String internalUrl) => internalUrl;

  @override
  void pushState(Object? state, String title, String url) {
    _state = state;
  }

  @override
  void replaceState(Object? state, String title, String url) {
    _state = state;
  }

  @override
  ui.VoidCallback addPopStateListener(ui_web.PopStateListener fn) => () {};

  @override
  Future<void> go(int count) async {}
}

/// `true` when `history.replaceState` actually works in this frame.
///
/// Probes with a REAL call — a same-URL replaceState is a semantic no-op
/// on normal browsers and throws TypeError in a stripped sandbox (the
/// issue's "capability-check via try/catch").
bool historyApiUsable() {
  try {
    web.window.history.replaceState(null, '', web.window.location.href);
    return true;
  } on Object {
    return false;
  }
}

/// Installs [NoOpUrlStrategy] when this build is the office pane (the
/// pane's URL is static — deep-link sync is meaningless there even where
/// the History API works) or when the probe says the sandbox stripped the
/// History API. Idempotent; leaves working hosts on the default strategy.
void installSandboxSafeUrlStrategy() {
  if (ui_web.urlStrategy is NoOpUrlStrategy) return;
  if (kFaBuildHost == 'office' || !historyApiUsable()) {
    setUrlStrategy(NoOpUrlStrategy());
  }
}
