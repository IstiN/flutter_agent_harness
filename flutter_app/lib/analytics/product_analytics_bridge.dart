// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The host product analytics bridge (gh-2391 addendum 3): a Dart→JS seam
/// for branded web shells.
///
/// Contract (documented in `docs/product-cloud.md`, "Host product
/// analytics bridge"):
/// - Fa calls `window.<hook>(name, params)` — the hook name is fixed
///   (`ainTrack` for the first host); the host owns consent gating and the
///   sink itself (the hook is a no-op before consent — Fa never gates,
///   never buffers, never retries).
/// - A missing (or non-function) hook, or a non-web platform, disables the
///   bridge: `track` is a no-op. Stock Fa and hosts without analytics are
///   byte-identical to before.
/// - Events carry no PII — only the fixed vocabulary documented in the
///   product docs (`agent_session_started`, `agent_chat_message_sent`,
///   `agent_theme_changed`).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'product_analytics_sink_stub.dart'
    if (dart.library.html) 'product_analytics_sink_web.dart';

export 'product_analytics_sink_stub.dart'
    if (dart.library.html) 'product_analytics_sink_web.dart'
    show platformProductAnalyticsSink;

/// One analytics emission: [event] is a documented name, [params] a
/// flat, PII-free string map.
typedef ProductAnalyticsSink =
    void Function(String event, Map<String, Object?> params);

/// The app-wide bridge singleton; call sites fire and forget.
final class ProductAnalyticsBridge {
  ProductAnalyticsBridge._();

  static final ProductAnalyticsBridge instance = ProductAnalyticsBridge._();

  /// The platform resolver; the VM/web split lives in the conditional
  /// files. Overridden only by tests.
  ProductAnalyticsSink? Function() _sinkResolver = platformProductAnalyticsSink;

  /// Fires [event] at the host hook, when one exists. Never throws, never
  /// blocks, never buffers — a host bug stays a host bug.
  void track(String event, Map<String, Object?> params) {
    final ProductAnalyticsSink? sink;
    try {
      sink = _sinkResolver();
    } on Object {
      return;
    }
    if (sink == null) return;
    try {
      sink(event, params);
    } on Object {
      // The host's sink is untrusted surface: a throwing hook must never
      // break the app (the same rule as every other host bridge).
    }
  }

  /// Test seam: force the sink (or null = disabled) without touching the
  /// platform conditional. Every test that installs one restores via
  /// [restorePlatformSinkResolver].
  @visibleForTesting
  void useSinkForTest(ProductAnalyticsSink? sink) {
    _sinkResolver = sink == null ? () => null : () => sink;
  }

  /// Test seam: back to the platform resolver.
  @visibleForTesting
  void restorePlatformSinkResolver() {
    _sinkResolver = platformProductAnalyticsSink;
  }
}
