// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The product analytics bridge tests (gh-2391 addendum 3): the Dart→JS
/// seam is no-op when the host hook is absent (stock and VM builds), and
/// forwards exactly the documented (event, params) pairs when wired.
library;

import 'package:fa/analytics/product_analytics_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    ProductAnalyticsBridge.instance.restorePlatformSinkResolver();
  });

  group('ProductAnalyticsBridge', () {
    test('is a no-op on platforms without the host hook (VM stub)', () {
      // The VM resolves the stub sink (null): track must neither throw
      // nor reach anything — stock hosts never grow an analytics path.
      expect(
        () => ProductAnalyticsBridge.instance.track('agent_session_started', {
          'source': 'stock',
        }),
        returnsNormally,
      );
    });

    test('forwards exact (event, params) pairs when the host hook exists', () {
      final recorded = <List<Object?>>[];
      ProductAnalyticsBridge.instance.useSinkForTest((event, params) {
        recorded.add([event, params]);
      });
      ProductAnalyticsBridge.instance.track('agent_session_started', {
        'source': 'host',
      });
      ProductAnalyticsBridge.instance.track('agent_chat_message_sent', {
        'model': 'ain/aiin_flash',
      });
      ProductAnalyticsBridge.instance.track('agent_theme_changed', {
        'packId': 'aiin-porcelain',
      });
      expect(recorded, [
        [
          'agent_session_started',
          {'source': 'host'},
        ],
        [
          'agent_chat_message_sent',
          {'model': 'ain/aiin_flash'},
        ],
        [
          'agent_theme_changed',
          {'packId': 'aiin-porcelain'},
        ],
      ]);
    });

    test('a throwing host hook never breaks the caller', () {
      ProductAnalyticsBridge.instance.useSinkForTest((event, params) {
        throw StateError('host bug');
      });
      expect(
        () => ProductAnalyticsBridge.instance.track('agent_theme_changed', {
          'packId': 'x',
        }),
        returnsNormally,
      );
    });
  });
}
