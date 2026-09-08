// Enrollment: bearer auth at the upgrade, the enroll op, name binding,
// secret rotation and persistence. Port of the Go enroll_test.go.

import 'dart:io';

import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  late TestHub hub;
  setUp(() async => hub = await startTestHub());
  tearDown(() => hub.close());

  test('a missing or wrong bearer is refused before the upgrade', () async {
    for (final token in ['', 'wrong-secret']) {
      final request = await HttpClient()
          .getUrl(Uri.parse(hub.url.replaceFirst('ws://', 'http://')))
        ..headers.set('upgrade', 'websocket');
      if (token.isNotEmpty) {
        request.headers.set('authorization', 'Bearer $token');
      }
      final response = await request.close();
      expect(response.statusCode, 401);
    }
  });

  test('the master token connects', () async {
    final a = await TestAgent.create('a');
    final conn = await connect(hub, a);
    final info = await whois(conn, a.id);
    expect(info['online'], isTrue);
  });

  test('enroll round trip: issued secret dials in, master still works',
      () async {
    final (conn, a, secret) = await dialAndEnroll(hub);
    expect(secret, isNotEmpty);
    await conn.close();

    // The issued secret authenticates a fresh connection.
    final c2 = await connect(hub, a, bearer: secret);
    final info = await whois(c2, a.id);
    expect(info['online'], isTrue);
  });

  test('the enrolled secret is bound to the hello name', () async {
    final (conn, a, secret) = await dialAndEnroll(hub);
    await conn.close();

    // Same key, different name → access_denied (then the conn closes).
    final c2 = await dial(hub, bearer: secret);
    await c2.writeSigned(a, helloMap(a)..['name'] = 'mallory');
    final err = await c2.readOp('error', skip: const []);
    expect(err['code'], DapCodes.accessDenied);
    expect(await c2.read(), isNull, reason: 'reject is fatal');
  });

  test('enroll requires hello first and the master secret', () async {
    // enroll before hello → not_authenticated
    final c1 = await dial(hub);
    c1.writeJson({'t': 'enroll'});
    var err = await c1.readOp('error', skip: const []);
    expect(err['code'], DapCodes.notAuthenticated);

    // enroll on an agent-secret connection → access_denied
    final (conn, a, secret) = await dialAndEnroll(hub);
    await conn.close();
    final c2 = await connect(hub, a, bearer: secret);
    c2.writeJson({'t': 'enroll'});
    err = await c2.readOp('error', skip: const []);
    expect(err['code'], DapCodes.accessDenied);
  });

  test('re-enrolling replaces the old secret', () async {
    final (conn, a, secret1) = await dialAndEnroll(hub);
    conn.writeJson({'t': 'enroll'});
    final reply = await conn.readUntil((f) => f['t'] == 'enrolled');
    final secret2 = reply['secret'] as String;
    expect(secret2, isNot(secret1));
    await conn.close();

    // The old secret 401s now; the new one connects.
    final denied = await HttpClient()
        .getUrl(Uri.parse(hub.url.replaceFirst('ws://', 'http://')))
      ..headers.set('upgrade', 'websocket')
      ..headers.set('authorization', 'Bearer $secret1');
    expect((await denied.close()).statusCode, 401);
    final c3 = await connect(hub, a, bearer: secret2);
    await c3.close();
  });

  test('the hub refuses to start without a master secret', () {
    expect(
      () => DapHub(config: DapHubConfig(masterSecret: '')),
      throwsArgumentError,
    );
  });

  test('issued secrets survive a hub restart (file store)', () async {
    final dir = await Directory.systemTemp.createTemp('dap_hub_test');
    addTearDown(() => dir.delete(recursive: true));
    final secretStore = AtomicFileStore('${dir.path}/secrets.json');
    final fileHub = await startTestHub(secretStore: secretStore);
    final (conn, a, secret) = await dialAndEnroll(fileHub);
    await conn.close();
    // Flush the fire-and-forget persist before restarting.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await fileHub.close();

    final revived = await startTestHub(secretStore: secretStore);
    addTearDown(revived.close);
    final c2 = await connect(revived, a, bearer: secret);
    final info = await whois(c2, a.id);
    expect(info['online'], isTrue);
  });

  test('no plaintext secrets on disk or in logs', () async {
    final dir = await Directory.systemTemp.createTemp('dap_hub_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = AtomicFileStore('${dir.path}/secrets.json');
    final fileHub = await startTestHub(secretStore: store);
    final (conn, _, secret) = await dialAndEnroll(fileHub);
    await conn.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await fileHub.close();

    final onDisk = await File('${dir.path}/secrets.json').readAsString();
    expect(onDisk, isNot(contains(secret)));
    expect(fileHub.logLines.join('\n'), isNot(contains(secret)));
  });
}

/// Dials, hellos, enrolls; returns (conn, agent, issued secret).
Future<(TestConn, TestAgent, String)> dialAndEnroll(TestHub hub) async {
  final a = await TestAgent.create('alice');
  final conn = await connect(hub, a);
  conn.writeJson({'t': 'enroll'});
  final reply = await conn.readUntil((f) => f['t'] == 'enrolled');
  return (conn, a, reply['secret'] as String);
}
