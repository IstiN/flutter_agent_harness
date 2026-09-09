/// `LocalHub` (the production hub behind `fa hub serve`): fixed-port
/// binding, `/healthz`, and the hello handshake on the bound port.
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// A spec-valid signed hello frame for [identity] (the hub verifies the
/// Ed25519 signature, timestamp skew, and nonce).
Future<Map<String, dynamic>> signedHello(HubIdentity identity) async {
  final frame = <String, dynamic>{
    'op': 'hello',
    'v': 1,
    'pubkey': identity.signingPubkeyB64,
    'x25519': identity.dhPubkeyB64,
    'nonce': randomHex(16),
    'ts': DateTime.now().millisecondsSinceEpoch,
  };
  frame['sig'] = await signFrame(frame, identity.signingKeyPair);
  return frame;
}

void main() {
  group('LocalHub', () {
    test('binds the requested fixed port and answers /healthz', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      final freePort = hub.url.port;
      await hub.stop();

      final fixed = LocalHub(port: freePort);
      await fixed.start();
      addTearDown(fixed.stop);
      expect(fixed.url.port, freePort);

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.get('127.0.0.1', freePort, '/healthz');
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
    });

    test(
      'binding a taken port throws (the serve command probes first)',
      () async {
        final first = LocalHub(port: 0);
        await first.start();
        addTearDown(first.stop);
        final second = LocalHub(port: first.url.port);
        await expectLater(second.start(), throwsA(isA<SocketException>()));
      },
    );

    test('an enroll frame gets an enrolled reply with a secret', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      addTearDown(hub.stop);

      final ws = await WebSocket.connect(hub.url.toString());
      addTearDown(ws.close);
      ws.add(jsonEncode({'t': 'enroll'}));
      final reply = jsonDecode(await ws.first as String) as Map;
      expect(reply['t'], 'enrolled');
      expect((reply['secret'] as String?) ?? '', hasLength(32));
    });
  });

  group('password protection', () {
    HttpClient http() {
      final client = HttpClient();
      addTearDown(client.close);
      return client;
    }

    Future<int> probeWsStatus(
      Uri url, {
      String? bearer,
      String? queryToken,
    }) async {
      final client = http();
      var uri = url.replace(scheme: 'http');
      if (queryToken != null) {
        uri = uri.replace(
          queryParameters: {...uri.queryParameters, 'dap_token': queryToken},
        );
      }
      final request = await client.openUrl('GET', uri);
      request.headers
        ..set('connection', 'Upgrade')
        ..set('upgrade', 'websocket')
        ..set('sec-websocket-version', '13')
        ..set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
      if (bearer != null) {
        request.headers.set('authorization', 'Bearer $bearer');
      }
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    test('open hub keeps accepting credential-less upgrades', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      addTearDown(hub.stop);
      expect(hub.isProtected, isFalse);
      // A real WS connect proves the upgrade succeeded.
      final ws = await WebSocket.connect(hub.url.toString());
      addTearDown(ws.close);
    });

    test(
      'protected hub rejects missing and wrong credentials with 401',
      () async {
        final hub = LocalHub(port: 0, masterSecret: 's3cret');
        await hub.start();
        addTearDown(hub.stop);
        expect(hub.isProtected, isTrue);
        expect(await probeWsStatus(hub.url), 401);
        expect(await probeWsStatus(hub.url, bearer: 'wrong'), 401);
        expect(await probeWsStatus(hub.url, queryToken: 'wrong'), 401);
      },
    );

    test('master secret via Bearer header upgrades and may enroll', () async {
      final hub = LocalHub(port: 0, masterSecret: 's3cret');
      await hub.start();
      addTearDown(hub.stop);
      final ws = await WebSocket.connect(
        hub.url.toString(),
        headers: {'authorization': 'Bearer s3cret'},
      );
      addTearDown(ws.close);
      ws.add(jsonEncode({'t': 'enroll'}));
      final reply = jsonDecode(await ws.first as String) as Map;
      expect(reply['t'], 'enrolled');
      expect(reply['secret'], isA<String>());
    });

    test('master secret via dap_token query upgrades (browser path)', () async {
      final hub = LocalHub(port: 0, masterSecret: 's3cret');
      await hub.start();
      addTearDown(hub.stop);
      final ws = await WebSocket.connect('${hub.url}?dap_token=s3cret');
      addTearDown(ws.close);
    });

    test('enroll on a client-secret connection is unauthorized', () async {
      final stateFile = File(
        '${Directory.systemTemp.path}/hub_auth_test_${DateTime.now().microsecondsSinceEpoch}.json',
      );
      addTearDown(() async {
        if (await stateFile.exists()) await stateFile.delete();
      });
      final hub = LocalHub(
        port: 0,
        masterSecret: 's3cret',
        stateFile: stateFile,
      );
      await hub.start();
      addTearDown(hub.stop);

      // Master enrolls and receives a per-client secret.
      final master = await WebSocket.connect(
        hub.url.toString(),
        headers: {'authorization': 'Bearer s3cret'},
      );
      // enroll requires a known agentId to persist — hello first.
      // One subscription only (WebSocket is single-subscription): the
      // hub processes hello then enroll in send order, so wait straight
      // for the enrolled frame.
      master.add(jsonEncode(await signedHello(await HubIdentity.generate())));
      master.add(jsonEncode({'t': 'enroll'}));
      final enrolled = await master
          .where((e) => (jsonDecode(e as String) as Map)['t'] == 'enrolled')
          .first;
      final clientSecret =
          (jsonDecode(enrolled as String) as Map)['secret'] as String;
      await master.close();

      // The enrolled client secret authenticates upgrades...
      final client = await WebSocket.connect(
        hub.url.toString(),
        headers: {'authorization': 'Bearer $clientSecret'},
      );
      addTearDown(client.close);
      // ...but may NOT enroll (master-only on a protected hub).
      client.add(jsonEncode({'t': 'enroll'}));
      final reply = jsonDecode(await client.first as String) as Map;
      expect(reply['code'], 'unauthorized');
    });

    test('enrollments survive a hub restart via the state file', () async {
      final stateFile = File(
        '${Directory.systemTemp.path}/hub_state_test_${DateTime.now().microsecondsSinceEpoch}.json',
      );
      addTearDown(() async {
        if (await stateFile.exists()) await stateFile.delete();
      });
      final first = LocalHub(
        port: 0,
        masterSecret: 's3cret',
        stateFile: stateFile,
      );
      await first.start();
      final master = await WebSocket.connect(
        first.url.toString(),
        headers: {'authorization': 'Bearer s3cret'},
      );
      master.add(jsonEncode(await signedHello(await HubIdentity.generate())));
      master.add(jsonEncode({'t': 'enroll'}));
      final enrolled = await master
          .where((e) => (jsonDecode(e as String) as Map)['t'] == 'enrolled')
          .first;
      final clientSecret =
          (jsonDecode(enrolled as String) as Map)['secret'] as String;
      await master.close();
      await first.stop();

      // Restart against the same state file: master password and the
      // enrolled client both still authenticate, strangers do not.
      final second = LocalHub(port: 0, stateFile: stateFile);
      await second.start();
      addTearDown(second.stop);
      expect(second.isProtected, isTrue);

      final http1 = HttpClient();
      addTearDown(http1.close);
      Future<int> status(String? bearer) async {
        final request = await http1.openUrl(
          'GET',
          second.url.replace(scheme: 'http'),
        );
        request.headers
          ..set('connection', 'Upgrade')
          ..set('upgrade', 'websocket')
          ..set('sec-websocket-version', '13')
          ..set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
        if (bearer != null) {
          request.headers.set('authorization', 'Bearer $bearer');
        }
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await status(null), 401);
      expect(await status('wrong'), 401);
      // valid credentials complete the WS handshake
      final wsMaster = await WebSocket.connect(
        second.url.toString(),
        headers: {'authorization': 'Bearer s3cret'},
      );
      addTearDown(wsMaster.close);
      final wsClient = await WebSocket.connect(
        second.url.toString(),
        headers: {'authorization': 'Bearer $clientSecret'},
      );
      addTearDown(wsClient.close);
    });
  });

  group('fa_hub_client against a protected hub', () {
    test(
      'master-secret client enrolls; the issued secret reconnects',
      () async {
        final stateFile = File(
          '\${Directory.systemTemp.path}/hub_e2e_state_\${DateTime.now().microsecondsSinceEpoch}.json',
        );
        final clientConfigFile =
            '\${Directory.systemTemp.path}/hub_e2e_client_\${DateTime.now().microsecondsSinceEpoch}.json';
        addTearDown(() async {
          if (await stateFile.exists()) await stateFile.delete();
          final f = File(clientConfigFile);
          if (await f.exists()) await f.delete();
        });
        final hub = LocalHub(
          port: 0,
          masterSecret: 'hub-pw',
          stateFile: stateFile,
        );
        await hub.start();
        addTearDown(hub.stop);

        final identity = await HubIdentity.generate();
        final first = HubClient(
          config: HubConfig(url: hub.url.toString()),
          identity: identity,
          clientSecret: 'hub-pw',
          enroll: true,
          configFile: clientConfigFile,
          backoff: (int _) => const Duration(milliseconds: 5),
        );
        await first.connect();
        expect(first.welcomed, completes);
        // The enrolled frame lands after welcome and the persist is
        // fire-and-forget — poll until the issued secret is on disk.
        String? issued;
        for (var i = 0; i < 100 && issued == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          issued = readDapConfig(clientConfigFile)['clientSecret'] as String?;
        }
        await first.disconnect();
        expect(issued, isNotNull);
        expect(issued, isNot('hub-pw'));

        // Reconnect with the issued secret (no master): welcomed.
        final second = HubClient(
          config: HubConfig(url: hub.url.toString()),
          identity: identity,
          clientSecret: issued,
          configFile: clientConfigFile,
          backoff: (int _) => const Duration(milliseconds: 5),
        );
        await second.connect();
        expect(second.welcomed, completes);
        await second.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('a wrong password is rejected at the upgrade (401)', () async {
      final hub = LocalHub(port: 0, masterSecret: 'hub-pw');
      await hub.start();
      addTearDown(hub.stop);
      final identity = await HubIdentity.generate();
      final client = HubClient(
        config: HubConfig(url: hub.url.toString()),
        identity: identity,
        clientSecret: 'wrong',
        backoff: (int _) => const Duration(milliseconds: 5),
      );
      await expectLater(client.connect(), throwsA(anything));
    });
  });
}
