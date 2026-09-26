// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/fa_network_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fakes.dart';

/// Regression for the 404 reported during the UI review: the ai-native
/// auth routes (`/api/auth/*`, `/api/oauth-proxy/*`) live on
/// ai-native.cloud, NOT on the fa_network relay.
void main() {
  group('auth service routing', () {
    test('oauth-proxy routes go to authBaseUrl, not the relay', () async {
      final httpClient = FakeHttpClient()
        ..oauthProvidersResponse = http.Response(
          '{"providers":["google"]}',
          200,
        );
      final client = FaNetworkClient(
        baseUrl: Uri.parse('https://network.fa1.dev'),
        authBaseUrl: Uri.parse('https://ai-native.cloud'),
        httpClient: httpClient,
      );
      final providers = await client.oauthProviders();
      expect(providers, ['google']);
      expect(
        httpClient.requests.single.url.host,
        'ai-native.cloud',
        reason: 'auth routes must not hit the relay (it 404s them)',
      );
    });

    test('authBaseUrl defaults to https://ai-native.cloud', () {
      final client = FaNetworkClient(
        baseUrl: Uri.parse('https://network.fa1.dev'),
        httpClient: FakeHttpClient(),
      );
      expect(client.authBaseUrl.toString(), 'https://ai-native.cloud');
    });
  });
}
