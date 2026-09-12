// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Sandbox-safe web URL strategy seam (issue #202).
///
/// Host sandboxes that embed the app (Outlook OWA taskpanes strip
/// `history.replaceState` from their iframes) crash the web engine's
/// default deep-link URL sync before the first frame. The web impl probes
/// the History API and swaps in a no-op strategy when it is unavailable or
/// when this build IS the office pane; other platforms do nothing.
library;

export 'sandbox_url_strategy_stub.dart'
    if (dart.library.html) 'sandbox_url_strategy_web.dart';
