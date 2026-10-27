// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure classification of `__ext_host` messages (gh-1848 tier 2).
///
/// [routeExtHostMessage] is a pure function — no native dependency — but
/// it lives in the ext-host runtime whose only covering suite boots the JS
/// engine (skipped on bridge-less hosts, so it measured 0% there). These
/// tests keep every declared route covered on every host.
library;

import 'package:fa/services/ext/flutter_js_ext_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('routeExtHostMessage', () {
    test('ignores non-map payloads', () {
      expect(routeExtHostMessage('nope'), isA<ExtHostIgnore>());
      expect(routeExtHostMessage(42), isA<ExtHostIgnore>());
      expect(routeExtHostMessage(null), isA<ExtHostIgnore>());
    });

    test('routes a string fatal to ExtHostFatal', () {
      final route = routeExtHostMessage({'fatal': 'ext host died'});
      expect(route, isA<ExtHostFatal>());
      expect((route as ExtHostFatal).message, 'ext host died');
    });

    test('routes an invoke envelope to ExtHostInvokeReply', () {
      final message = {'invoke': '7', 'ok': true, 'value': 3};
      final route = routeExtHostMessage(message);
      expect(route, isA<ExtHostInvokeReply>());
      final reply = route as ExtHostInvokeReply;
      expect(reply.handle, '7');
      expect(reply.ok, isTrue);
      expect(reply.reply, same(message));
    });

    test('invoke wins over a seq field (precedence)', () {
      final route = routeExtHostMessage({'invoke': '1', 'seq': 2});
      expect(route, isA<ExtHostInvokeReply>());
    });

    test('routes a seq envelope to ExtHostBridgeRequest', () {
      final route = routeExtHostMessage({
        'seq': 12,
        'method': 'fs.read',
        'args': <String, Object?>{},
      });
      expect(route, isA<ExtHostBridgeRequest>());
      final request = route as ExtHostBridgeRequest;
      expect(request.seq, 12);
      expect(request.method, 'fs.read');
    });

    test('maps without fatal/invoke/int seq are ignored', () {
      expect(routeExtHostMessage({'unrelated': true}), isA<ExtHostIgnore>());
      // A non-int seq is not a bridge request.
      expect(routeExtHostMessage({'seq': '12'}), isA<ExtHostIgnore>());
    });
  });
}
