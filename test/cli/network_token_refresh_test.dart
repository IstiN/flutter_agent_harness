// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/network_commands.dart';
import 'package:flutter_agent_harness/src/cli/network_store.dart';
import 'package:flutter_agent_harness/src/network/connector/device_api.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/network/network_account_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  // All cases run against a frozen clock (2026-01-01T00:00:00Z) so expiry
  // margins are deterministic.
  final now = DateTime.utc(2026);

  group('proactive refresh before authenticated device REST calls', () {
    test(
      'a token inside the 2-minute margin refreshes before the call',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'almost-expired-jwt',
            refreshToken: 'refresh-secret',
            // 90s left: past is not required — the margin window must trigger.
            expiresAt: now.add(const Duration(seconds: 90)),
          )
          ..device = const NetworkDeviceCredentials(
            deviceId: 'device-stable',
            deviceToken: 'device-secret',
          );
        final output = <String>[];
        final requests = <http.Request>[];
        final runner = commandRunner(
          store: store,
          out: output.add,
          handler: (request) async {
            requests.add(request);
            if (request.url.path == '/api/auth/refresh') {
              return _tokenResponse('fresh-jwt', 'next-refresh');
            }
            expect(
              request.headers['authorization'],
              'Bearer fresh-jwt',
              reason: 'device REST must sign with the refreshed token',
            );
            return http.Response(jsonEncode({'devices': []}), 200);
          },
        );

        expect(await runner.run(['devices']), 0);
        expect(requests.map((r) => r.url.path), [
          '/api/auth/refresh',
          '/api/devices',
        ]);
        expect(store.account?.accessToken, 'fresh-jwt');
        expect(store.account?.refreshToken, 'next-refresh');
        // Same-account refresh must preserve the stored device identity.
        expect(store.device?.deviceId, 'device-stable');
        expect(store.device?.deviceToken, 'device-secret');
        // Exactly one info line per refresh, no token material in output.
        expect(
          output.where((line) => line.contains('refreshed')),
          hasLength(1),
        );
        expect(output.join('\n'), isNot(contains('refresh-secret')));
        expect(output.join('\n'), isNot(contains('almost-expired-jwt')));
      },
    );

    test(
      'an account with no declared expiry refreshes before the call',
      () async {
        final store = MemoryNetworkStore()
          ..account = const NetworkAccount(
            accessToken: 'opaque-bearer',
            refreshToken: 'refresh-secret',
          );
        final requests = <http.Request>[];
        final runner = commandRunner(
          store: store,
          handler: (request) async {
            requests.add(request);
            if (request.url.path == '/api/auth/refresh') {
              return _tokenResponse('fresh-jwt', null);
            }
            return http.Response(jsonEncode({'devices': []}), 200);
          },
        );

        expect(await runner.run(['devices']), 0);
        expect(requests.map((r) => r.url.path), [
          '/api/auth/refresh',
          '/api/devices',
        ]);
        expect(store.account?.accessToken, 'fresh-jwt');
      },
    );

    test(
      'a comfortably valid token is used as-is (no refresh chatter)',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'valid-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.add(const Duration(hours: 1)),
          );
        final requests = <http.Request>[];
        final runner = commandRunner(
          store: store,
          handler: (request) async {
            requests.add(request);
            return http.Response(jsonEncode({'devices': []}), 200);
          },
        );

        expect(await runner.run(['devices']), 0);
        expect(requests.map((r) => r.url.path), ['/api/devices']);
        expect(requests.single.headers['authorization'], 'Bearer valid-jwt');
      },
    );
  });

  group('reactive 401 handling on device REST', () {
    test(
      'a 401 refreshes once, retries with the new token, keeps the device',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'stale-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.add(const Duration(hours: 1)),
          )
          ..device = const NetworkDeviceCredentials(
            deviceId: 'device-stable',
            deviceToken: 'device-secret',
            personalNetworkId: 'personal-1',
            dmPrivateKeys: {'agent@device-stable': 'private-seed'},
          );
        final output = <String>[];
        final requests = <http.Request>[];
        final bearerForPath = <String>[];
        final runner = commandRunner(
          store: store,
          out: output.add,
          handler: (request) async {
            requests.add(request);
            if (request.url.path == '/api/auth/refresh') {
              return _tokenResponse('fresh-jwt', 'next-refresh');
            }
            bearerForPath.add(request.headers['authorization'] ?? '');
            if (bearerForPath.length == 1) {
              return http.Response(jsonEncode({'error': 'token expired'}), 401);
            }
            return http.Response(
              jsonEncode({
                'devices': [
                  {'deviceId': 'device-stable', 'name': 'workstation'},
                ],
              }),
              200,
            );
          },
        );

        expect(await runner.run(['devices']), 0);
        expect(requests.map((r) => r.url.path), [
          '/api/devices',
          '/api/auth/refresh',
          '/api/devices',
        ]);
        expect(bearerForPath, ['Bearer stale-jwt', 'Bearer fresh-jwt']);
        expect(store.account?.accessToken, 'fresh-jwt');
        expect(store.account?.refreshToken, 'next-refresh');
        // Retry-once must not touch the enrolled device identity.
        expect(store.device?.deviceId, 'device-stable');
        expect(store.device?.deviceToken, 'device-secret');
        expect(store.device?.personalNetworkId, 'personal-1');
        expect(store.device?.dmPrivateKeys, {
          'agent@device-stable': 'private-seed',
        });
        expect(output.join('\n'), contains('device-stable'));
        expect(output.join('\n'), isNot(contains('refresh-secret')));
      },
    );

    test(
      'a second 401 after the refreshed retry is not retried again',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'stale-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.add(const Duration(hours: 1)),
          );
        final errors = <String>[];
        var deviceCalls = 0;
        final runner = commandRunner(
          store: store,
          error: errors.add,
          handler: (request) async {
            if (request.url.path == '/api/auth/refresh') {
              return _tokenResponse('fresh-jwt', 'next-refresh');
            }
            deviceCalls++;
            return http.Response(jsonEncode({'error': 'still rejected'}), 401);
          },
        );

        expect(await runner.run(['devices']), 1);
        expect(deviceCalls, 2, reason: 'the call is retried exactly once');
        expect(errors.join('\n'), contains('still rejected'));
      },
    );

    test('a 401 with no refresh token names the login fallback', () async {
      final store = MemoryNetworkStore()
        ..account = NetworkAccount(
          accessToken: 'headless-jwt',
          expiresAt: now.add(const Duration(hours: 1)),
        );
      final errors = <String>[];
      final runner = commandRunner(
        store: store,
        error: errors.add,
        handler: (_) async =>
            http.Response(jsonEncode({'error': 'unauthorized'}), 401),
      );

      expect(await runner.run(['devices']), 1);
      final text = errors.join('\n');
      expect(text, contains('login --jwt'));
      expect(text, isNot(contains('headless-jwt')));
    });
  });

  group('refresh failures surface the named login fallback', () {
    test(
      'a failing refresh endpoint names the fallback without secrets',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'expired-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.subtract(const Duration(minutes: 1)),
          );
        final output = <String>[];
        final errors = <String>[];
        final runner = commandRunner(
          store: store,
          out: output.add,
          error: errors.add,
          handler: (request) async {
            expect(request.url.path, '/api/auth/refresh');
            // The body echoes token fields: the surfaced reason must redact.
            return http.Response(
              jsonEncode({
                'error': 'refresh rejected',
                'refresh_token': 'refresh-secret',
              }),
              400,
            );
          },
        );

        expect(await runner.run(['devices']), 1);
        final text = errors.join('\n');
        expect(text, contains('refresh failed'));
        expect(text, contains('login --jwt'));
        expect(text, contains('refresh rejected'));
        expect(text, isNot(contains('refresh-secret')));
        expect(output.join('\n'), isNot(contains('refresh-secret')));
      },
    );

    test(
      'a transport failure while refreshing also names the fallback',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'expired-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.subtract(const Duration(minutes: 1)),
          );
        final errors = <String>[];
        final runner = commandRunner(
          store: store,
          error: errors.add,
          handler: (_) async => throw const SocketException('auth down'),
        );

        expect(await runner.run(['devices']), 1);
        final text = errors.join('\n');
        expect(text, contains('refresh failed'));
        expect(text, contains('login --jwt'));
      },
    );
  });

  group('fa network status', () {
    test(
      'refreshes an expired account and prints the refreshed expiry',
      () async {
        final store = MemoryNetworkStore()
          ..account = NetworkAccount(
            accessToken: 'expired-jwt',
            refreshToken: 'refresh-secret',
            expiresAt: now.subtract(const Duration(minutes: 1)),
          )
          ..device = const NetworkDeviceCredentials(
            deviceId: 'device-stable',
            deviceToken: 'device-secret',
          );
        final output = <String>[];
        final runner = commandRunner(
          store: store,
          out: output.add,
          handler: (request) async {
            expect(request.url.path, '/api/auth/refresh');
            return _tokenResponse('fresh-jwt', 'next-refresh');
          },
        );

        expect(await runner.run(['status']), 0);
        final text = output.join('\n');
        expect(text, contains('access token refreshed'));
        expect(text, contains('access expiry: 2026-01-01T01:00:00.000Z'));
        expect(text, contains('(valid)'));
        expect(text, isNot(contains('(expired)')));
        expect(text, isNot(contains('refresh-secret')));
        expect(store.account?.accessToken, 'fresh-jwt');
        expect(store.device?.deviceId, 'device-stable');
      },
    );

    test('an expired account without a refresh token keeps reporting local '
        'state and names the fallback', () async {
      final store = MemoryNetworkStore()
        ..account = NetworkAccount(
          accessToken: 'expired-jwt',
          expiresAt: now.subtract(const Duration(minutes: 1)),
        );
      final output = <String>[];
      final errors = <String>[];
      final runner = commandRunner(
        store: store,
        out: output.add,
        error: errors.add,
        handler: (_) => throw StateError(
          'status refresh must be the only '
          'HTTP attempt',
        ),
      );

      expect(await runner.run(['status']), 1);
      expect(output.join('\n'), contains('account:'));
      expect(output.join('\n'), contains('(expired)'));
      final text = errors.join('\n');
      expect(text, contains('access token expired'));
      expect(text, contains('login --jwt'));
    });
  });
}

http.Response _tokenResponse(String access, String? refresh) => http.Response(
  jsonEncode({
    'accessToken': access,
    'refreshToken': ?refresh,
    'expiresIn': 3600,
  }),
  200,
);

NetworkCommandRunner commandRunner({
  required NetworkCredentialStore store,
  required Future<http.Response> Function(http.Request) handler,
  void Function(String)? out,
  void Function(String)? error,
}) {
  final client = MockClient(handler);
  return NetworkCommandRunner(
    store: store,
    accountClient: NetworkAccountClient(
      baseUrl: 'https://auth.test',
      httpClient: client,
      clock: () => DateTime.utc(2026),
    ),
    deviceClient: DeviceEnrollmentClient(httpClient: client),
    relayBaseUrl: 'https://relay.test',
    clock: () => DateTime.utc(2026),
    out: out,
    error: error,
  );
}

/// Minimal transport error type for the transport-failure test.
final class SocketException implements Exception {
  const SocketException(this.message);

  final String message;

  @override
  String toString() => 'SocketException: $message';
}
