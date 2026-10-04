// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B: the shared JS-app error record (core package surface —
/// the wire format every host parses and relays).
@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('JsAppErrorEvent', () {
    test('fromLogJson parses the bootstrap wire format', () {
      final event = JsAppErrorEvent.fromLogJson({
        'kind': 'showError',
        'message': 'Undefined variable: foo',
        'stack': 'at widget.js:12:3',
        'fingerprint': 'fp-1',
      });
      expect(event, isNotNull);
      expect(event!.kind, JsAppErrorKind.showError);
      expect(event.message, 'Undefined variable: foo');
      expect(event.stack, 'at widget.js:12:3');
      expect(event.dedupKey, 'fp-1');
    });

    test('fromLogJson maps every capture kind', () {
      final expected = <String, JsAppErrorKind>{
        'showError': JsAppErrorKind.showError,
        'callback': JsAppErrorKind.callback,
        'onerror': JsAppErrorKind.onerror,
        'unhandledrejection': JsAppErrorKind.unhandledRejection,
        'render': JsAppErrorKind.render,
        'bootstrap': JsAppErrorKind.bootstrap,
      };
      for (final entry in expected.entries) {
        final event = JsAppErrorEvent.fromLogJson({
          'kind': entry.key,
          'message': 'm',
        });
        expect(event?.kind, entry.value, reason: entry.key);
      }
    });

    test('fromLogJson rejects malformed records', () {
      expect(JsAppErrorEvent.fromLogJson({'kind': 'onerror'}), isNull);
      expect(
        JsAppErrorEvent.fromLogJson({'kind': 'onerror', 'message': 42}),
        isNull,
      );
    });

    test('unknown kinds fall back to onerror; fingerprint wins the dedup key', () {
      final event = JsAppErrorEvent.fromLogJson({
        'kind': 'something-new',
        'message': 'm',
        'stack': 's',
      });
      expect(event?.kind, JsAppErrorKind.onerror);
      const bare = JsAppErrorEvent(
        kind: JsAppErrorKind.callback,
        message: 'boom',
        stack: 'at a\nat b',
      );
      expect(bare.dedupKey, 'boom\nat a');
    });
  });
}
