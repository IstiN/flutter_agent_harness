// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/network_commands.dart';
import 'package:flutter_agent_harness/src/cli/network_oauth_io.dart';
import 'package:flutter_agent_harness/src/cli/network_store.dart';
import 'package:flutter_agent_harness/src/cli/network_store_io.dart';
import 'package:flutter_agent_harness/src/network/connector/device_api.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/network/network_account_client.dart';
import 'package:flutter_agent_harness/src/network/network_roster.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('fa network login --jwt + file persistence', () {
    late Directory home;

    setUp(() async => home = await Directory.systemTemp.createTemp('fa-net-'));
    tearDown(() async {
      if (await home.exists()) await home.delete(recursive: true);
    });

    test(
      'stores the JWT with metadata, redacts output, and logout clears',
      () async {
        final token = jwt({
          'sub': 'user-1',
          'email': 'dev@example.test',
          'exp': 4102444800,
        });
        final output = <String>[];
        final errors = <String>[];
        final store = FileNetworkCredentialStore(home.path);
        final runner = commandRunner(
          store: store,
          handler: (_) => throw StateError('login --jwt must not use HTTP'),
          out: output.add,
          error: errors.add,
        );

        expect(await runner.run(['login', '--jwt', token]), 0);
        expect(output.join('\n'), contains('dev@example.test'));
        expect(output.join('\n'), isNot(contains(token)));
        expect(errors, isEmpty);
        final file = File('${home.path}/.fah/network/account.json');
        expect(await file.exists(), isTrue);
        final json = jsonDecode(await file.readAsString()) as Map;
        expect(json['accessToken'], token);
        expect(json['email'], 'dev@example.test');
        final restored = await FileNetworkCredentialStore(
          home.path,
        ).readAccount();
        expect(restored?.accessToken, token);
        expect(restored?.subject, 'user-1');
        if (!Platform.isWindows) {
          expect(await file.stat().then((stat) => stat.mode & 63), 0);
        }

        expect(await runner.run(['logout']), 0);
        expect(await file.exists(), isFalse);
        expect(await store.readAccount(), isNull);
        expect(await store.readDevice(), isNull);
      },
    );
  });

  group('command dispatch and login options', () {
    test('help forms and unknown commands return usage exit codes', () async {
      final output = <String>[];
      final errors = <String>[];
      final runner = commandRunner(
        store: MemoryNetworkStore(),
        handler: (_) => throw StateError('local usage must not use HTTP'),
        out: output.add,
        error: errors.add,
      );

      expect(await runner.run([]), 64);
      expect(await runner.run(['help']), 0);
      expect(await runner.run(['--help']), 0);
      expect(await runner.run(['unknown']), 64);
      expect(output, hasLength(3));
      expect(output, everyElement(NetworkCommandRunner.usage));
      expect(errors.join('\n'), contains('unknown network command: unknown'));
    });

    test('JWT and provider flags accept separate and equals forms', () async {
      final store = MemoryNetworkStore()
        ..device = const NetworkDeviceCredentials(
          deviceId: 'previous-device',
          deviceToken: 'previous-secret',
        );
      final runner = commandRunner(
        store: store,
        handler: (_) => throw StateError('pasted JWTs must not use HTTP'),
      );

      expect(await runner.run(['login', '--jwt=first-token']), 0);
      expect(store.account?.accessToken, 'first-token');
      expect(store.device, isNull);
      expect(
        await runner.run([
          'login',
          '--provider',
          'github',
          '--jwt',
          'second-token',
        ]),
        0,
      );
      expect(store.account?.accessToken, 'second-token');
      expect(
        await runner.run(['login', '--provider=github', '--jwt=third-token']),
        0,
      );
      expect(store.account?.accessToken, 'third-token');
    });

    final invalid = <List<String>, String>{
      ['login', '--jwt']: '--jwt requires a token',
      ['login', '--jwt', '   ']: '--jwt requires a token',
      ['login', '--provider']: '--provider requires a name',
      ['login', 'pasted-secret']: 'unknown login option',
    };
    for (final entry in invalid.entries) {
      test('login rejects ${entry.value}', () async {
        final errors = <String>[];
        final runner = commandRunner(
          store: MemoryNetworkStore(),
          handler: (_) => throw StateError('invalid input must not use HTTP'),
          error: errors.add,
        );

        expect(await runner.run(entry.key), 64);
        expect(errors.join('\n'), contains(entry.value));
        expect(errors.join('\n'), isNot(contains('pasted-secret')));
      });
    }

    test('login reports when loopback OAuth is unavailable', () async {
      final errors = <String>[];
      final runner = commandRunner(
        store: MemoryNetworkStore(),
        handler: (_) => throw StateError('unavailable OAuth must not use HTTP'),
        error: errors.add,
      );

      expect(await runner.run(['login']), 64);
      expect(errors.join('\n'), contains('OAuth loopback is unavailable'));
    });

    test('login rejects an empty OAuth provider before starting', () async {
      final errors = <String>[];
      final runner = commandRunner(
        store: MemoryNetworkStore(),
        handler: (_) => throw StateError('invalid provider must not use HTTP'),
        startReceiver: () async => fail('receiver must not start'),
        openUrl: (_) async => fail('browser must not open'),
        error: errors.add,
      );

      expect(await runner.run(['login', '--provider=']), 64);
      expect(errors.join('\n'), contains('--provider requires a name'));
    });
  });

  test(
    'enroll sends name/platform + account bearer and persists device',
    () async {
      final store = MemoryNetworkStore()
        ..account = const NetworkAccount(accessToken: 'account-jwt');
      final requests = <http.Request>[];
      final runner = commandRunner(
        store: store,
        platform: 'macos',
        handler: (request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'deviceId': 'device-1',
              'deviceToken': 'device-secret',
              'personalNetwork': {'id': 'personal-1'},
            }),
            200,
          );
        },
      );

      expect(await runner.run(['enroll', '--name', 'workstation']), 0);
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://relay.test/api/devices/enroll');
      expect(request.headers['authorization'], 'Bearer account-jwt');
      expect(jsonDecode(request.body), {
        'name': 'workstation',
        'platform': 'macos',
      });
      expect(store.device?.deviceId, 'device-1');
      expect(store.device?.deviceToken, 'device-secret');
      expect(store.device?.personalNetworkId, 'personal-1');
    },
  );

  test('status reports account/device/phase without either bearer', () async {
    final output = <String>[];
    final store = MemoryNetworkStore()
      ..account = const NetworkAccount(
        accessToken: 'account-secret',
        email: 'owner@example.test',
      )
      ..device = const NetworkDeviceCredentials(
        deviceId: 'device-1',
        deviceToken: 'device-secret',
        personalNetworkId: 'personal-1',
        name: 'workstation',
      );
    final runner = commandRunner(
      store: store,
      out: output.add,
      handler: (_) => throw StateError('status is local'),
    );

    expect(await runner.run(['status']), 0);
    final text = output.join('\n');
    expect(text, contains('account: owner@example.test'));
    expect(text, contains('device: device-1 (workstation)'));
    expect(text, contains('personal network: personal-1'));
    expect(text, contains('phase: enrolled'));
    expect(text, isNot(contains('account-secret')));
    expect(text, isNot(contains('device-secret')));
  });

  test('HTTP error diagnostics redact token-shaped response fields', () async {
    final errors = <String>[];
    final store = MemoryNetworkStore()
      ..account = const NetworkAccount(accessToken: 'account-jwt');
    final runner = commandRunner(
      store: store,
      error: errors.add,
      handler: (_) async => http.Response(
        jsonEncode({
          'error': 'rejected',
          'access_token': 'returned-secret',
          'deviceToken': 'device-secret',
        }),
        400,
      ),
    );

    expect(await runner.run(['devices']), 1);
    final text = errors.join('\n');
    expect(text, contains('rejected'));
    expect(text, contains('<redacted>'));
    expect(text, isNot(contains('returned-secret')));
    expect(text, isNot(contains('device-secret')));
  });

  test('devices lists own machines; rename PATCHes THIS device', () async {
    final output = <String>[];
    final store = MemoryNetworkStore()
      ..account = const NetworkAccount(accessToken: 'account-jwt')
      ..device = const NetworkDeviceCredentials(
        deviceId: 'device-1',
        deviceToken: 'device-secret',
        name: 'old-host',
      );
    final requests = <http.Request>[];
    final runner = commandRunner(
      store: store,
      out: output.add,
      handler: (request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'deviceId': 'device-1',
                  'name': 'old-host',
                  'friendlyName': 'Workstation',
                  'createdAt': '2026-01-02T03:04:05Z',
                },
                {'deviceId': 'device-2', 'name': 'build-box'},
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'deviceId': 'device-1', 'friendlyName': 'New Mac'}),
          200,
        );
      },
    );

    expect(await runner.run(['devices']), 0);
    expect(
      output.join('\n'),
      contains('device-1  Workstation (host: old-host)'),
    );
    expect(output.join('\n'), contains('device-2  build-box'));
    expect(await runner.run(['rename', 'New', 'Mac']), 0);
    expect(requests, hasLength(2));
    expect(requests[0].method, 'GET');
    expect(requests[0].url.path, '/api/devices');
    expect(requests[0].headers['authorization'], 'Bearer account-jwt');
    expect(requests[1].method, 'PATCH');
    expect(requests[1].url.path, '/api/devices/device-1/name');
    expect(jsonDecode(requests[1].body), {'name': 'New Mac'});
    expect(requests[1].headers['authorization'], 'Bearer account-jwt');
    expect(store.device?.friendlyName, 'New Mac');
  });

  group('rename validation', () {
    final invalid = <List<String>, String>{
      ['rename', '--clear', 'other']: '--clear cannot be combined with a name',
      ['rename']: 'rename requires a name, or --clear',
      ['rename', '   ']: 'rename requires a name',
      ['rename', 'x' * 65]: 'friendly name must be at most 64 characters',
    };
    for (final entry in invalid.entries) {
      test('rejects ${entry.value}', () async {
        final errors = <String>[];
        final runner = commandRunner(
          store: MemoryNetworkStore(),
          handler: (_) => throw StateError('invalid input must not use HTTP'),
          error: errors.add,
        );

        expect(await runner.run(entry.key), 64);
        expect(errors.join('\n'), contains(entry.value));
      });
    }

    test('requires an enrolled device', () async {
      final errors = <String>[];
      final runner = commandRunner(
        store: MemoryNetworkStore()
          ..account = const NetworkAccount(accessToken: 'account-jwt'),
        handler: (_) => throw StateError('missing device must not use HTTP'),
        error: errors.add,
      );

      expect(await runner.run(['rename', 'valid-name']), 64);
      expect(errors.join('\n'), contains('not enrolled; run enroll first'));
    });
  });

  test(
    'rename --clear sends an empty friendly name and clears local status',
    () async {
      final store = MemoryNetworkStore()
        ..account = const NetworkAccount(accessToken: 'account-jwt')
        ..device = const NetworkDeviceCredentials(
          deviceId: 'device-1',
          deviceToken: 'device-secret',
          friendlyName: 'Old Name',
        );
      late String sentName;
      final runner = commandRunner(
        store: store,
        handler: (request) async {
          sentName = (jsonDecode(request.body) as Map)['name'] as String;
          return http.Response(
            jsonEncode({'deviceId': 'device-1', 'friendlyName': ''}),
            200,
          );
        },
      );

      expect(await runner.run(['rename', '--clear']), 0);
      expect(sentName, isEmpty);
      expect(store.device?.friendlyName, isNull);
    },
  );

  test('expired accounts refresh before device REST calls', () async {
    final store = MemoryNetworkStore()
      ..account = NetworkAccount(
        accessToken: 'expired-jwt',
        refreshToken: 'refresh-secret',
        expiresAt: DateTime.utc(2025),
      );
    final requests = <http.Request>[];
    final runner = commandRunner(
      store: store,
      handler: (request) async {
        requests.add(request);
        if (request.url.path == '/api/auth/refresh') {
          expect(jsonDecode(request.body), {'refreshToken': 'refresh-secret'});
          return http.Response(
            jsonEncode({
              'access_token': 'fresh-jwt',
              'refresh_token': 'next-refresh',
              'expires_in': 3600,
            }),
            200,
          );
        }
        expect(request.url.path, '/api/devices');
        expect(request.headers['authorization'], 'Bearer fresh-jwt');
        return http.Response(jsonEncode({'devices': []}), 200);
      },
    );

    expect(await runner.run(['devices']), 0);
    expect(requests, hasLength(2));
    expect(store.account?.accessToken, 'fresh-jwt');
    expect(store.account?.refreshToken, 'next-refresh');
  });

  test(
    'expired accounts without refresh tokens fail with login guidance',
    () async {
      final errors = <String>[];
      final store = MemoryNetworkStore()
        ..account = NetworkAccount(
          accessToken: 'expired-jwt',
          expiresAt: DateTime.utc(2025),
        );
      final runner = commandRunner(
        store: store,
        handler: (_) => throw StateError('failed refresh must not use HTTP'),
        error: errors.add,
      );

      expect(await runner.run(['devices']), 1);
      expect(errors.join('\n'), contains('access token expired'));
      expect(errors.join('\n'), contains('login --jwt'));
    },
  );

  test(
    'devices --roster renders the socket projection without account HTTP',
    () async {
      final output = <String>[];
      final store = MemoryNetworkStore()
        ..device = const NetworkDeviceCredentials(
          deviceId: 'device-1',
          deviceToken: 'device-secret',
        );
      final runner = commandRunner(
        store: store,
        out: output.add,
        handler: (_) => throw StateError('--roster uses the socket reader'),
        rosterReader: () async => [
          const NetworkDeviceRow(
            deviceId: 'device-1',
            name: 'workstation',
            presence: 'online',
            networkIds: {'personal-1'},
            agentAddresses: {'mailbox@device-1'},
            sessionIds: {'session-1'},
          ),
        ],
      );

      expect(await runner.run(['devices', '--roster']), 0);
      expect(output.join('\n'), contains('roster devices: 1'));
      expect(
        output.join('\n'),
        contains('device-1  workstation  online  networks=personal-1'),
      );
    },
  );

  test('desktop OAuth runs initiate, browser, callback and exchange', () async {
    final store = MemoryNetworkStore();
    final requests = <http.Request>[];
    final opened = <Uri>[];
    final receiver = _FakeReceiver(
      Uri.parse('http://127.0.0.1:9876/callback?code=one-time&state=state-1'),
    );
    final runner = commandRunner(
      store: store,
      startReceiver: () async => receiver,
      openUrl: (uri) async => opened.add(uri),
      handler: (request) async {
        requests.add(request);
        if (request.url.path.endsWith('/initiate')) {
          return http.Response(
            jsonEncode({
              'auth_url': 'https://auth.test/authorize?client=fa',
              'state': 'state-1',
              'expires_in': 300,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'access_token': 'oauth-access',
            'refresh_token': 'oauth-refresh',
            'expires_in': 3600,
          }),
          200,
        );
      },
    );

    expect(await runner.run(['login']), 0);
    expect(opened.single.toString(), 'https://auth.test/authorize?client=fa');
    expect(receiver.closed, isTrue);
    expect(store.account?.accessToken, 'oauth-access');
    expect(store.account?.refreshToken, 'oauth-refresh');
    expect(store.account?.expiresAt, isNotNull);
    expect(requests, hasLength(2));
    expect(jsonDecode(requests[0].body), {
      'provider': 'google',
      'client_redirect_uri': 'http://127.0.0.1:9876/callback',
      'client_type': 'desktop',
      'environment': 'prod',
    });
    expect(jsonDecode(requests[1].body), {
      'code': 'one-time',
      'state': 'state-1',
    });
  });

  test(
    'OAuth rejects a state mismatch and still closes the receiver',
    () async {
      final receiver = _FakeReceiver(
        Uri.parse('http://127.0.0.1:9876/callback?code=x&state=attacker'),
      );
      final flow = NetworkOAuthFlow(
        client: NetworkAccountClient(
          baseUrl: 'https://auth.test',
          httpClient: MockClient(
            (_) async => http.Response(
              jsonEncode({'auth_url': 'https://auth.test/a', 'state': 'good'}),
              200,
            ),
          ),
        ),
        startReceiver: () async => receiver,
        openUrl: (_) async {},
      );

      await expectLater(flow.signIn(), throwsA(isA<NetworkAuthException>()));
      expect(receiver.closed, isTrue);
    },
  );

  test(
    'OAuth loopback handles invalid requests and one valid callback',
    () async {
      final receiver = await NetworkOAuthLoopback.bind();
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await receiver.close();
      });

      final wrongPath = await client.get(
        receiver.redirectUri.replace(path: '/not-the-callback'),
      );
      expect(wrongPath.statusCode, HttpStatus.notFound);
      expect(wrongPath.body, 'Not found');
      expect(wrongPath.headers['content-type'], contains('text/plain'));

      final wrongMethod = await client.post(receiver.redirectUri);
      expect(wrongMethod.statusCode, HttpStatus.notFound);

      final expected = receiver.redirectUri.replace(
        queryParameters: {'code': 'one-time', 'state': 'state-1'},
      );
      final callback = receiver.callback;
      final accepted = await client.get(expected);
      expect(accepted.statusCode, HttpStatus.ok);
      expect(accepted.headers['content-type'], contains('text/html'));
      expect(accepted.body, contains('login complete'));
      final callbackUri = await callback;
      expect(callbackUri.path, expected.path);
      expect(callbackUri.queryParameters, expected.queryParameters);

      final duplicate = await client.get(
        receiver.redirectUri.replace(
          queryParameters: {'code': 'ignored', 'state': 'other'},
        ),
      );
      expect(duplicate.statusCode, HttpStatus.ok);
      expect(await callback, callbackUri);
      await receiver.close();
      await receiver.close();
    },
  );
}

NetworkCommandRunner commandRunner({
  required NetworkCredentialStore store,
  required Future<http.Response> Function(http.Request) handler,
  void Function(String)? out,
  void Function(String)? error,
  String platform = 'test-os',
  NetworkStartOAuthReceiver? startReceiver,
  NetworkOpenAuthUrl? openUrl,
  NetworkRosterReader? rosterReader,
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
    deviceName: 'test-host',
    platform: platform,
    startReceiver: startReceiver,
    openUrl: openUrl,
    rosterReader: rosterReader,
    clock: () => DateTime.utc(2026),
    out: out,
    error: error,
  );
}

String jwt(Map<String, Object?> claims) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none', 'typ': 'JWT'})}.${part(claims)}.signature';
}

final class _FakeReceiver implements NetworkOAuthCallbackReceiver {
  _FakeReceiver(this._callback);

  final Uri _callback;
  bool closed = false;

  @override
  Uri get redirectUri => Uri.parse('http://127.0.0.1:9876/callback');

  @override
  Future<Uri> get callback async => _callback;

  @override
  Future<void> close() async => closed = true;
}
