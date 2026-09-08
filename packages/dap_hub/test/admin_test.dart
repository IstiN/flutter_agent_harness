// The admin REST API and identity eviction. Port of the Go
// admin_test.go + admin_evict_test.go (+ store round trip).

import 'dart:convert';
import 'dart:io';

import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';
import 'package:test/test.dart';

import 'enroll_test.dart' show dialAndEnroll;
import 'harness.dart';

void main() {
  late TestHub hub;
  setUp(() async => hub = await startTestHub());
  tearDown(() => hub.close());

  String httpUrl(String path) =>
      '${hub.url.replaceFirst('ws://', 'http://').replaceAll('/ws', '')}'
      '$path';

  Future<HttpClientResponse> admin(
    String method,
    String path, {
    String? bearer,
    String? body,
  }) async {
    final request = await HttpClient().openUrl(
      method,
      Uri.parse(httpUrl(path)),
    );
    if (bearer != null) {
      request.headers.set('authorization', 'Bearer $bearer');
    }
    if (body != null) request.write(body);
    return request.close();
  }

  test('healthz answers ok without auth', () async {
    final response = await admin('GET', '/healthz');
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), 'ok');
  });

  test('admin endpoints 401 without/with a wrong token', () async {
    for (final token in [null, 'wrong']) {
      expect(
          (await admin('GET', '/api/channels', bearer: token)).statusCode, 401);
      expect(
          (await admin('GET', '/api/agents', bearer: token)).statusCode, 401);
      expect(
        (await admin('PUT', '/api/channels/x/acl',
                bearer: token, body: '{"allowed":[]}'))
            .statusCode,
        401,
      );
      expect(
        (await admin('DELETE', '/api/agents/x', bearer: token)).statusCode,
        401,
      );
    }
  });

  test('channels list, ACL set, agents list', () async {
    final a = await TestAgent.create('a');
    final b = await TestAgent.create('b');
    final ca = await connect(hub, a);
    final cb = await connect(hub, b);
    await joinChan(ca, a, 'general');
    await joinChan(cb, b, 'general');
    await joinChan(ca, a, 'empty');

    final channels =
        await admin('GET', '/api/channels', bearer: adminTestToken);
    expect(channels.statusCode, 200);
    final rows = jsonDecode(await utf8.decoder.bind(channels).join()) as List;
    final byName = {
      for (final row in rows) (row as Map)['name'] as String: row,
    };
    expect(byName['general']?['members'], 2);
    expect(byName['general']?['aclSize'], 0);
    expect(byName['empty']?['members'], 1);

    // PUT an ACL (upserts the channel).
    final set = await admin('PUT', '/api/channels/vip/acl',
        bearer: adminTestToken, body: '{"allowed":["${a.pubB64}"]}');
    expect(set.statusCode, 204);
    final after = await admin('GET', '/api/channels', bearer: adminTestToken);
    final rows2 = jsonDecode(await utf8.decoder.bind(after).join()) as List;
    final vip = rows2.firstWhere((r) => (r as Map)['name'] == 'vip') as Map;
    expect(vip['aclSize'], 1);

    // Bad body → 400.
    final bad = await admin('PUT', '/api/channels/vip/acl',
        bearer: adminTestToken, body: '{nope');
    expect(bad.statusCode, 400);

    final agents = await admin('GET', '/api/agents', bearer: adminTestToken);
    expect(agents.statusCode, 200);
    final list = jsonDecode(await utf8.decoder.bind(agents).join()) as List;
    expect(list.length, 2);
  });

  group('evict', () {
    test('evicting an offline agent removes the identity', () async {
      final a = await TestAgent.create('a');
      final b = await TestAgent.create('b');
      final ca = await connect(hub, a);
      final cb = await connect(hub, b);
      await sendDM(ca, a, b.id, 'm1', 'Q1JD');
      await cb.readOp('msg', skip: const []);
      await cb.close();
      await waitOffline(ca, b.id);

      final evicted =
          await admin('DELETE', '/api/agents/${b.id}', bearer: adminTestToken);
      expect(evicted.statusCode, 204);
      ca.writeJson({'op': 'whois', 'agentId': b.id});
      final reply = await ca.readUntil(
        (f) => f['op'] == 'error' || f['op'] == 'agent_info',
      );
      expect(reply['code'], 'unknown_agent');
    });

    test('evicting an online agent is refused with 409', () async {
      final b = await TestAgent.create('b');
      await connect(hub, b);
      final response =
          await admin('DELETE', '/api/agents/${b.id}', bearer: adminTestToken);
      expect(response.statusCode, 409);
    });

    test('evicting an unknown agent is 404', () async {
      final response = await admin('DELETE', '/api/agents/ffffffffffffffff',
          bearer: adminTestToken);
      expect(response.statusCode, 404);
    });

    test('eviction purges the issued secret of the name', () async {
      final (conn, a, secret) = await dialAndEnroll(hub);
      await conn.close();
      // wait until offline via a second observer
      final observer = await TestAgent.create('obs');
      final co = await connect(hub, observer);
      await waitOffline(co, a.id);

      final evicted =
          await admin('DELETE', '/api/agents/${a.id}', bearer: adminTestToken);
      expect(evicted.statusCode, 204);

      // The secret no longer dials in.
      final denied = await HttpClient().getUrl(
        Uri.parse(httpUrl('/ws')),
      )
        ..headers.set('authorization', 'Bearer $secret');
      expect((await denied.close()).statusCode, 401);
    });

    test('eviction keeps a secret whose name is still held', () async {
      // Two identities enrolled under the SAME name share the secret.
      final (conn, a, secret) = await dialAndEnroll(hub);
      await conn.close();
      final a2 = await TestAgent.create('alice'); // same name, new keys
      final c2 = await connect(hub, a2, bearer: secret);
      await c2.close();

      final observer = await TestAgent.create('obs');
      final co = await connect(hub, observer);
      await waitOffline(co, a.id);
      await waitOffline(co, a2.id);

      // Evict only the first identity; the name is still held by a2.
      final evicted =
          await admin('DELETE', '/api/agents/${a.id}', bearer: adminTestToken);
      expect(evicted.statusCode, 204);

      // The shared secret must still dial in (as alice → a2's keys).
      final c3 = await connect(hub, a2, bearer: secret);
      final info = await whois(c3, a2.id);
      expect(info['online'], isTrue);
    });
  });

  group('persistence', () {
    test('channel registry survives a hub restart', () async {
      final dir = await Directory.systemTemp.createTemp('dap_hub_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = AtomicFileStore('${dir.path}/channels.json');
      final first = await startTestHub(channelStore: store);
      final a = await TestAgent.create('a');
      final ca = await connect(first, a);
      await joinChan(ca, a, 'persisted', 'cpub');
      first.hub.adminSetAcl(
          adminTestToken, 'persisted', '{"allowed":["${a.pubB64}"]}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await first.close();

      final revived = await startTestHub(channelStore: store);
      addTearDown(revived.close);
      final channel = revived.hub.channels['persisted'];
      expect(channel, isNotNull);
      expect(channel!.pubkey, 'cpub');
      expect(channel.allowed, [a.pubB64]);
      expect(channel.members, isEmpty, reason: 'membership is in-memory v1');
    });

    test('a corrupt store file boots clean', () async {
      final dir = await Directory.systemTemp.createTemp('dap_hub_test');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/channels.json').writeAsString('{corrupt');
      final store = AtomicFileStore('${dir.path}/channels.json');
      final clean = await startTestHub(channelStore: store);
      addTearDown(clean.close);
      expect(clean.hub.channels, isEmpty);
    });

    test('writes to a bad path are swallowed and logged', () async {
      final store = AtomicFileStore('/no/such/dir/channels.json');
      final broken = await startTestHub(channelStore: store);
      addTearDown(broken.close);
      final a = await TestAgent.create('a');
      final ca = await connect(broken, a);
      await joinChan(ca, a, 'general');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        broken.logLines.any((l) => l.contains('write channels failed')),
        isTrue,
      );
    });
  });
}
