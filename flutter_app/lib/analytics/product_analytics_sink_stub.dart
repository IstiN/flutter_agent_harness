// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web platforms have no host product analytics hook (gh-2391
/// addendum 3): the bridge resolves to no sink and every `track` is a
/// no-op. The product shell is a web surface.
library;

import 'product_analytics_bridge.dart' show ProductAnalyticsSink;

/// The platform [ProductAnalyticsSink] resolver: none on native hosts.
ProductAnalyticsSink? platformProductAnalyticsSink() => null;
