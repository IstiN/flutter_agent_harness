// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be
// found in the LICENSE file.

import 'package:fa/network/oauth_callback_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeOAuthCallbackMessage', () {
    test('decodes a grant hand-off', () {
      final message = decodeOAuthCallbackMessage({
        'type': faOAuthMessageType,
        'code': 'c-1',
        'state': 'st-1',
        'error': null,
        'error_description': null,
        'ts': 123,
      });
      expect(message, isNotNull);
      expect(message!.code, 'c-1');
      expect(message.state, 'st-1');
      expect(message.error, isNull);
      expect(message.errorDescription, isNull);
    });

    test('decodes a provider error hand-off', () {
      final message = decodeOAuthCallbackMessage({
        'type': faOAuthMessageType,
        'code': null,
        'state': 'st-1',
        'error': 'access_denied',
        'error_description': 'user denied',
      });
      expect(message, isNotNull);
      expect(message!.code, isNull);
      expect(message.error, 'access_denied');
      expect(message.errorDescription, 'user denied');
    });

    test('rejects foreign message types', () {
      expect(
        decodeOAuthCallbackMessage({
          'type': 'aiin_oauth_code',
          'code': 'c-1',
        }),
        isNull,
      );
      expect(
        decodeOAuthCallbackMessage({'type': 'openrouter_oauth_code'}),
        isNull,
      );
    });

    test('rejects non-payload objects and incomplete hand-offs', () {
      expect(decodeOAuthCallbackMessage(null), isNull);
      expect(decodeOAuthCallbackMessage(42), isNull);
      expect(decodeOAuthCallbackMessage(['type']), isNull);
      // Right type but neither a code nor an error — cannot complete.
      expect(
        decodeOAuthCallbackMessage({'type': faOAuthMessageType}),
        isNull,
      );
    });
  });

  group('OAuthCallbackMessage.toUri', () {
    test('rebuilds the callback URI the poll would have produced', () {
      final uri = decodeOAuthCallbackMessage({
        'type': faOAuthMessageType,
        'code': 'c-1',
        'state': 'st-1',
      })!
          .toUri('https://fa1.dev');
      expect(uri.toString(), 'https://fa1.dev/oauth/callback?code=c-1&state=st-1');
    });

    test('carries error parameters through for the flow to surface', () {
      final uri = decodeOAuthCallbackMessage({
        'type': faOAuthMessageType,
        'error': 'access_denied',
        'error_description': 'user denied',
      })!
          .toUri('https://fa1.dev');
      expect(uri.queryParameters['error'], 'access_denied');
      expect(uri.queryParameters['error_description'], 'user denied');
      expect(uri.queryParameters.containsKey('code'), isFalse);
    });

    test('keeps special characters intact through the round-trip', () {
      final uri = decodeOAuthCallbackMessage({
        'type': faOAuthMessageType,
        'code': 'a/b+c=d',
        'state': 'st&1',
      })!
          .toUri('https://fa1.dev');
      expect(uri.queryParameters['code'], 'a/b+c=d');
      expect(uri.queryParameters['state'], 'st&1');
    });
  });

  group('isTrustedCallbackOrigin', () {
    test('accepts the production callback page and the app origin', () {
      expect(isTrustedCallbackOrigin('https://fa1.dev', 'https://fa1.dev'),
          isTrue);
      // A cross-origin opener (extension/Office pane) still trusts the
      // callback page it was redirected to.
      expect(
        isTrustedCallbackOrigin('https://fa1.dev', 'chrome-extension://abc'),
        isTrue,
      );
    });

    test('rejects everything else, including look-alikes', () {
      expect(
        isTrustedCallbackOrigin('https://fa1.dev.evil.com', 'https://fa1.dev'),
        isFalse,
      );
      expect(
        isTrustedCallbackOrigin('http://fa1.dev', 'https://fa1.dev'),
        isFalse,
      );
      expect(isTrustedCallbackOrigin('', 'https://fa1.dev'), isFalse);
    });
  });
}
