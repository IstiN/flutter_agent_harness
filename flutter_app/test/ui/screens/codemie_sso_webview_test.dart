// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/codemie_sso_flow_steps.dart';
import 'package:fa/ui/screens/codemie_sso_webview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A valid callback token: base64 JSON with a `cookies` object.
String _token(Map<String, Object?> cookies) => base64.encode(
  utf8.encode(jsonEncode({'cookies': cookies})),
);

void main() {
  group('codeMieNavigationDecision', () {
    test('a localhost callback with a token is intercepted', () {
      String? token;
      final decision = codeMieNavigationDecision(
        'http://localhost:48127/?token=abc123',
        onToken: (t) => token = t,
      );

      expect(decision, NavigationDecision.prevent);
      expect(token, 'abc123');
    });

    test('the 127.0.0.1 loopback form is intercepted too', () {
      String? token;
      final decision = codeMieNavigationDecision(
        'http://127.0.0.1:48127/?token=abc',
        onToken: (t) => token = t,
      );

      expect(decision, NavigationDecision.prevent);
      expect(token, 'abc');
    });

    test('a localhost hit without a token is prevented but silent', () {
      var called = 0;
      final decision = codeMieNavigationDecision(
        'http://localhost:48127/?other=1',
        onToken: (t) => called++,
      );

      expect(decision, NavigationDecision.prevent);
      expect(called, 0);
    });

    test('an empty token is ignored', () {
      var called = 0;
      final decision = codeMieNavigationDecision(
        'http://localhost:48127/?token=',
        onToken: (t) => called++,
      );

      expect(decision, NavigationDecision.prevent);
      expect(called, 0);
    });

    test('the SSO host itself navigates normally', () {
      var called = 0;
      final decision = codeMieNavigationDecision(
        'https://codemie.example.com/v1/auth/login/48127',
        onToken: (t) => called++,
      );

      expect(decision, NavigationDecision.navigate);
      expect(called, 0);
    });

    test('an unparseable URL navigates (never crashes the delegate)', () {
      final decision = codeMieNavigationDecision(
        'http://%', // percent-encoding garbage: Uri.tryParse fails
      );

      expect(decision, NavigationDecision.navigate);
    });

    test('the intercepted token feeds the real credentials decoder', () {
      // _completeWithToken routes the callback token through
      // decodeCodeMieSsoCredentials — the exact payload CodeMie bakes into
      // the redirect must complete the flow.
      final credentials = decodeCodeMieSsoCredentials(
        _token({'codemie_access_token': 'jwt-1'}),
        'https://codemie.lab.epam.com',
      );

      expect(credentials.cookies, {'codemie_access_token': 'jwt-1'});
      expect(credentials.apiUrl, isNotEmpty);
      expect(credentials.expiresAt, greaterThan(0));
    });
  });
}
