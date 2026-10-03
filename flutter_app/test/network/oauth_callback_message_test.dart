// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be
// found in the LICENSE file.

import 'package:fa/network/oauth_callback_message.dart';
import 'package:fa/network/production_origins.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeOAuthCallbackMessage', () {
    test('derives the production origin from the shared constant', () {
      // Drift guard: the trust check must track the shared site origin,
      // not a second spelling of it.
      expect(productionSiteOrigin, 'https://fa1.dev');
      expect(isTrustedCallbackOrigin(productionSiteOrigin, 'other'), isTrue);
    });

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

  group('OAuthCallbackMessage.matchesExpectedState', () {
    final message = decodeOAuthCallbackMessage({
      'type': faOAuthMessageType,
      'code': 'c-1',
      'state': 'st-1',
    })!;

    test('accepts the echoed state', () {
      expect(message.matchesExpectedState('st-1'), isTrue);
    });

    test('rejects another flow\'s state', () {
      expect(message.matchesExpectedState('st-other'), isFalse);
    });

    test('stays ungated when the auth URL carried no state', () {
      expect(message.matchesExpectedState(null), isTrue);
    });
  });

  group('oauthCallbackFromStorage', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, Object?> payload({int? ts}) => {
      'type': faOAuthMessageType,
      'code': 'c-1',
      'state': 'st-1',
      'error': null,
      'error_description': null,
      'ts': ts ?? now,
    };

    test('accepts a fresh entry', () {
      final message = oauthCallbackFromStorage(payload(), now);
      expect(message, isNotNull);
      expect(message!.code, 'c-1');
    });

    test('accepts an entry right at the freshness edge', () {
      final message = oauthCallbackFromStorage(
        payload(ts: now - oauthCallbackStorageMaxAgeMs),
        now,
      );
      expect(message, isNotNull);
    });

    test('rejects a stale entry', () {
      expect(
        oauthCallbackFromStorage(payload(ts: now - oauthCallbackStorageMaxAgeMs - 1), now),
        isNull,
      );
    });

    test('rejects a future-dated entry (clock skew guard)', () {
      expect(oauthCallbackFromStorage(payload(ts: now + 5), now), isNull);
    });

    test('rejects an entry without a timestamp', () {
      expect(oauthCallbackFromStorage(payload()..remove('ts'), now), isNull);
    });

    test('rejects foreign payloads', () {
      expect(
        oauthCallbackFromStorage(payload()..['type'] = 'aiin_oauth_code', now),
        isNull,
      );
      expect(oauthCallbackFromStorage('not a map', now), isNull);
      expect(oauthCallbackFromStorage(null, now), isNull);
    });
  });
}
