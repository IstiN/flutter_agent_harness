// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web resolution of the host product analytics hook (gh-2391 addendum
/// 3): `window.<hook>` — `ainTrack` for the first host — exposed by the
/// host wrapper's site-wide script. The hook self-gates on consent; Fa
/// never checks, buffers or retries. A missing or non-function hook keeps
/// every call a no-op.
library;

import 'dart:js_interop';

import 'product_analytics_bridge.dart' show ProductAnalyticsSink;

/// The window-global function name Fa calls, per the host contract in
/// `docs/product-cloud.md`. One constant, one place.
const String productAnalyticsHookName = 'ainTrack';

@JS(productAnalyticsHookName)
external JSAny? get _productTrackHook;

/// The platform [ProductAnalyticsSink]: present on web builds (each call
/// re-checks the hook, so a late-injected wrapper still works), null
/// elsewhere (the conditional import picks the stub off web).
ProductAnalyticsSink? platformProductAnalyticsSink() {
  return (String event, Map<String, Object?> params) {
    try {
      final hook = _productTrackHook;
      if (hook == null || !hook.isA<JSFunction>()) return;
      final payload = <String, Object?>{
        for (final entry in params.entries)
          if (entry.value != null) entry.key: entry.value!,
      };
      (hook as JSFunction).callAsFunction(null, event.toJS, payload.jsify());
    } on Object {
      // Absent hook or a throwing sink: stay silent — the host's
      // analytics is untrusted surface and must never break the app.
    }
  };
}
