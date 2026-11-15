// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/device_name.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_agent_harness/src/network/connector/offline_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import 'device_connector_service_test.dart'
    show
        FakeChatSessionSource,
        FakeTransport,
        MemoryDeviceTokenStore,
        pumpUntilOnline,
        rosterPatches;
import 'fakes.dart';

const _enrollBody =
    '{"deviceId":"dev-1","deviceToken":"dt-secret",'
    '"personalNetwork":{"id":"net-personal"}}';

Future<DeviceConnectorService> _service({
  required FakeHttpClient http,
  required MemoryDeviceTokenStore tokens,
  String computedName = 'EPBYGROW03B0',
  DeviceChatSessionSource? chatSessionSource,
}) async {
  final manager = NetworkSessionManager(
    baseUrl: testBase,
    wallet: await KeyWallet.load(MemoryWalletBackend()),
    httpClient: http,
    jwtToken: 'jwt-1',
  );
  return DeviceConnectorService(
    sessionManager: manager,
    tokenStore: tokens,
    transport: FakeTransport(),
    outbox: MemoryOutboxStore(),
    chatSessionSource: chatSessionSource,
    rosterDebounce: Duration.zero,
    deviceNameProvider: () async => computedName,
  );
}

MemoryDeviceTokenStore _legacyTokens({bool repaired = false}) =>
    MemoryDeviceTokenStore()
      ..stored = DeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt-secret',
        personalNetworkId: 'net-personal',
        deviceNameRepaired: repaired,
      );

void main() {
  group('enrollment device names', () {
    test('platform probe always returns a usable name', () async {
      final name = await platformEnrollmentDeviceName();
      expect(name.trim(), isNotEmpty);
      expect(isGenericDeviceName(name), isFalse);
    });

    test('keeps a meaningful desktop hostname', () {
      expect(
        enrollmentDeviceName(
          operatingSystem: 'macos',
          hostname: '  EPBYGROW03B0  ',
          user: 'uladzimir',
        ),
        'EPBYGROW03B0',
      );
    });

    test('desktop placeholders fall back to OS and short user', () {
      for (final hostname in [
        '',
        'localhost',
        'LOCALHOST.localdomain',
        'unknown',
        'device',
      ]) {
        expect(
          enrollmentDeviceName(
            operatingSystem: 'macos',
            hostname: hostname,
            user: 'uladzimir',
          ),
          'macOS (uladzimir)',
          reason: hostname,
        );
      }
      expect(
        enrollmentDeviceName(operatingSystem: 'linux', hostname: 'localhost'),
        'Linux',
      );
    });

    test('mobile prefers the owner/device name, then human model', () {
      expect(
        enrollmentDeviceName(
          operatingSystem: 'android',
          deviceName: 'Duo',
          model: 'Pixel 8',
          manufacturer: 'Google',
        ),
        'Duo',
      );
      expect(
        enrollmentDeviceName(
          operatingSystem: 'android',
          deviceName: 'device',
          model: 'Pixel 8',
          manufacturer: 'Google',
        ),
        'Google Pixel 8',
      );
      expect(
        enrollmentDeviceName(
          operatingSystem: 'android',
          model: 'Google Pixel 8',
          manufacturer: 'Google',
        ),
        'Google Pixel 8',
      );
      expect(
        enrollmentDeviceName(operatingSystem: 'android', model: 'unknown'),
        'Android device',
      );
      expect(
        enrollmentDeviceName(operatingSystem: 'ios', model: 'unknown'),
        'iPhone',
      );
    });
  });

  test('stored pre-repair credentials opt into the one-shot migration', () {
    final legacy = DeviceCredentials.tryFromJson(jsonDecode(_enrollBody));
    expect(legacy, isNotNull);
    expect(legacy!.deviceNameRepaired, isFalse);
    final repaired = DeviceCredentials.tryFromJson(
      legacy.withDeviceNameRepaired().toJson(),
    );
    expect(repaired?.deviceNameRepaired, isTrue);
  });

  test('fresh enrollment sends the computed non-generic name', () async {
    final http = FakeHttpClient()
      ..respond(200, body: _enrollBody)
      ..respond(200, body: '{"ticket":"tk-1"}');
    final service = await _service(
      http: http,
      tokens: MemoryDeviceTokenStore(),
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);

    final enroll = http.requests.singleWhere(
      (request) => request.url.path == '/api/devices/enroll',
    );
    expect(jsonDecode(enroll.body), {
      'name': 'EPBYGROW03B0',
      'platform': isA<String>(),
    });
    expect(
      http.requests.where((request) => request.url.path == '/api/devices'),
      isEmpty,
      reason: 'a freshly well-named enrollment needs no repair probe',
    );
  });

  test('fresh enrollment sanitizes a generic provider result', () async {
    final http = FakeHttpClient()
      ..respond(200, body: _enrollBody)
      ..respond(200, body: '{"ticket":"tk-1"}');
    final service = await _service(
      http: http,
      tokens: MemoryDeviceTokenStore(),
      computedName: 'localhost',
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);

    final enroll = http.requests.singleWhere(
      (request) => request.url.path == '/api/devices/enroll',
    );
    final name = (jsonDecode(enroll.body) as Map)['name'];
    expect(name, isA<String>());
    expect(isGenericDeviceName(name as String), isFalse);
  });

  test(
    'legacy generic enrollment is repaired once and survives restart',
    () async {
      final http = FakeHttpClient()
        ..respond(
          200,
          body: '{"devices":[{"deviceId":"dev-1","name":"device"}]}',
        )
        ..respond(
          200,
          body: '{"deviceId":"dev-1","friendlyName":"EPBYGROW03B0"}',
        )
        ..respond(200, body: '{"ticket":"tk-1"}')
        ..respond(200, body: '{"ticket":"tk-2"}');
      final tokens = _legacyTokens();
      final first = await _service(http: http, tokens: tokens);
      await first.start();
      await pumpUntilOnline(first);

      final patch = http.requests.singleWhere(
        (request) => request.url.path == '/api/devices/dev-1/name',
      );
      expect(patch.method, 'PATCH');
      expect(jsonDecode(patch.body), {'name': 'EPBYGROW03B0'});
      expect(first.ownDevice?.friendlyName, 'EPBYGROW03B0');
      expect(tokens.stored?.deviceNameRepaired, isTrue);
      await first.dispose();

      final second = await _service(http: http, tokens: tokens);
      addTearDown(second.dispose);
      await second.start();
      await pumpUntilOnline(second);
      expect(
        http.requests.where((request) => request.url.path == '/api/devices'),
        hasLength(1),
      );
      expect(
        http.requests.where(
          (request) => request.url.path == '/api/devices/dev-1/name',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a legacy missing/null enrollment name is repaired without re-enroll',
    () async {
      final http = FakeHttpClient()
        ..respond(200, body: '{"devices":[{"deviceId":"dev-1","name":null}]}')
        ..respond(
          200,
          body: '{"deviceId":"dev-1","friendlyName":"EPBYGROW03B0"}',
        )
        ..respond(200, body: '{"ticket":"tk-1"}');
      final service = await _service(http: http, tokens: _legacyTokens());
      addTearDown(service.dispose);

      await service.start();
      await pumpUntilOnline(service);

      expect(
        http.requests.where(
          (request) => request.url.path == '/api/devices/enroll',
        ),
        isEmpty,
      );
      expect(
        http.requests
            .singleWhere(
              (request) => request.url.path == '/api/devices/dev-1/name',
            )
            .method,
        'PATCH',
      );
      expect(service.ownFriendlyName, 'EPBYGROW03B0');
    },
  );

  test(
    'an existing owner friendly name is never overwritten by repair',
    () async {
      final http = FakeHttpClient()
        ..respond(
          200,
          body:
              '{"devices":[{"deviceId":"dev-1","name":"device",'
              '"friendlyName":"Studio"}]}',
        )
        ..respond(200, body: '{"ticket":"tk-1"}');
      final tokens = _legacyTokens();
      final service = await _service(http: http, tokens: tokens);
      addTearDown(service.dispose);

      await service.start();
      await pumpUntilOnline(service);

      expect(service.ownFriendlyName, 'Studio');
      expect(tokens.stored?.deviceNameRepaired, isTrue);
      expect(
        http.requests.where(
          (request) => request.url.path == '/api/devices/dev-1/name',
        ),
        isEmpty,
      );
    },
  );

  test('an already meaningful enrollment name needs no PATCH', () async {
    final http = FakeHttpClient()
      ..respond(
        200,
        body: '{"devices":[{"deviceId":"dev-1","name":"EPBYGROW03B0"}]}',
      )
      ..respond(200, body: '{"ticket":"tk-1"}');
    final service = await _service(http: http, tokens: _legacyTokens());
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);

    expect(service.ownDevice?.name, 'EPBYGROW03B0');
    expect(
      http.requests.where(
        (request) => request.url.path == '/api/devices/dev-1/name',
      ),
      isEmpty,
    );
  });

  test('persisted-only projection publishes a sleeping DM agent', () async {
    final http = FakeHttpClient()
      ..respond(200, body: '{"ticket":"tk-1"}')
      ..respond(200, body: '{"patched":"dev-1"}');
    final service = await _service(
      http: http,
      tokens: _legacyTokens(repaired: true),
      chatSessionSource: FakeChatSessionSource(const [
        (id: 'offline-chat', live: false),
      ]),
    );
    addTearDown(service.dispose);

    await service.start();
    await pumpUntilOnline(service);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final patch = rosterPatches(http).single;
    final agent = (patch['agents']! as List).single as Map;
    expect(agent['state'], 'wake_on_dm');
    expect(agent['exposed'], isTrue);
    expect(agent['dmPub'], isA<String>());
    expect(((patch['sessions']! as List).single as Map)['state'], 'wake_on_dm');
  });
}
