// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/ws_connector_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('liftBearerIntoQuery', () {
    test('appends the bearer token as ?token= on a bare URI', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'Bearer sess-tok-123',
      });
      expect(uri.queryParameters['token'], 'sess-tok-123');
      expect(uri.toString(), contains('?token=sess-tok-123'));
    });

    test('preserves existing query parameters', () {
      final uri = liftBearerIntoQuery(
        Uri.parse('wss://network.fa1.dev/ws?channel=abc&x=1'),
        {'Authorization': 'Bearer tok'},
      );
      expect(uri.queryParameters['channel'], 'abc');
      expect(uri.queryParameters['x'], '1');
      expect(uri.queryParameters['token'], 'tok');
    });

    test('replaces an existing stale token', () {
      final uri = liftBearerIntoQuery(
        Uri.parse('wss://network.fa1.dev/ws?token=old'),
        {'Authorization': 'Bearer fresh'},
      );
      expect(uri.queryParameters['token'], 'fresh');
    });

    test('accepts a lowercase bearer scheme (RFC 6750 auth-scheme is '
        'case-insensitive)', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'bearer sess-tok-123',
      });
      expect(uri.queryParameters['token'], 'sess-tok-123');
    });

    test('accepts an uppercase bearer scheme', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'BEARER sess-tok-123',
      });
      expect(uri.queryParameters['token'], 'sess-tok-123');
    });

    test('accepts a mixed-case bearer scheme', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'BeArEr sess-tok-123',
      });
      expect(uri.queryParameters['token'], 'sess-tok-123');
    });

    test('returns the URI unchanged without an Authorization header', () {
      final uri = liftBearerIntoQuery(
        Uri.parse('wss://network.fa1.dev/ws?channel=abc'),
        const {},
      );
      expect(uri.queryParameters['token'], isNull);
      expect(uri.queryParameters['channel'], 'abc');
    });

    test('returns the URI unchanged when the header is not a bearer', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'Basic dXNlcg==',
      });
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('returns the URI unchanged when the bearer value is empty', () {
      final uri = liftBearerIntoQuery(Uri.parse('wss://network.fa1.dev/ws'), {
        'Authorization': 'Bearer   ',
      });
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });
  });
}
