// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The auth service returns snake_case from /api/oauth-proxy/exchange but
/// camelCase from /api/auth/refresh (verified against IstiN/auth
/// handlers) — TokenBundle must accept both (the UI-review FormatException
/// came from the snake_case reality).
void main() {
  group('TokenBundle wire shapes', () {
    final now = DateTime.utc(2026, 9, 26);

    test('exchange snake_case (access_token, expires_in)', () {
      final bundle = TokenBundle.fromJson(const {
        'access_token': 'at-1',
        'refresh_token': 'rt-1',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'refresh_expires_in': 86400,
      }, now: now);
      expect(bundle.accessToken, 'at-1');
      expect(bundle.refreshToken, 'rt-1');
      expect(bundle.expiresAt, now.add(const Duration(seconds: 3600)));
      expect(bundle.refreshExpiresAt, now.add(const Duration(seconds: 86400)));
    });

    test('refresh camelCase (accessToken, expiresIn)', () {
      final bundle = TokenBundle.fromJson(const {
        'accessToken': 'at-2',
        'refreshToken': 'rt-2',
        'tokenType': 'Bearer',
        'expiresIn': 3600,
        'refreshExpiresIn': 86400,
      }, now: now);
      expect(bundle.accessToken, 'at-2');
      expect(bundle.expiresAt, now.add(const Duration(seconds: 3600)));
    });
  });
}
