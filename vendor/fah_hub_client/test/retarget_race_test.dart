/// Retarget lifecycle races: a connect-loop cycle parked inside
/// `WebSocket.connect` by a retarget must never touch shared state when
/// its socket completes late (stale-socket guards), and inbound payloads
/// that cannot be decrypted must surface, not vanish.
library;

import 'dart:async';
import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final tinyBackoff = (int _) => const Duration(milliseconds: 5);

/// TCP proxy whose backend→client direction is held shut until
/// [release]: the client's `WebSocket.connect` parks mid-handshake, which
/// is exactly the in-flight cycle a second retarget supersedes.
class GatedProxy {
  GatedProxy._(this._listener);

  final ServerSocket _listener;
  Socket? _client;
  Socket? _backend;
  final List<List<int>> _held = [];
  bool _released = false;

  static Future<GatedProxy> start(InternetAddress host, int port) async {
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    final proxy = GatedProxy._(listener);
    listener.listen((client) async {
      if (proxy._client != null) return; // one gated client at a time
      proxy._client = client;
      final backend = await Socket.connect(host, port);
      proxy._backend = backend;
      client.listen((List<int> data) => backend.add(data),
          onError: (Object _) {}, onDone: backend.destroy);
      backend.listen((List<int> data) {
        if (proxy._released) {
          client.add(data);
        } else {
          proxy._held.add(data);
        }
      }, onError: (Object _) {}, onDone: client.destroy);
    });
    return proxy;
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_listener.port}/ws');

  void release() {
    _released = true;
    final client = _client;
    if (client != null) {
      for (final data in _held) {
        client.add(data);
      }
    }
    _held.clear();
  }

  Future<void> stop() async {
    await _client?.close();
    await _backend?.close();
    await _listener.close();
  }
}

void main() {
  late FakeHub hub;

  setUp(() async {
    hub = FakeHub();
    await hub.start();
  });

  tearDown(() async {
    await hub.stop();
  });

  test('a cycle parked mid-connect by a retarget never hellos when released',
      () async {
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    await client.connect(); // hellosSeen == 1

    final proxy = await GatedProxy.start(
      InternetAddress.loopbackIPv4,
      hub.url.port,
    );
    // Superseded generation: parks inside WebSocket.connect (gate shut).
    unawaited(client
        .retarget(url: proxy.url.toString(), keys: await HubIdentity.generate())
        .then((_) {}, onError: (Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Live generation: retarget again while the first cycle is parked.
    final freshKeys = await HubIdentity.generate();
    final id = await client.retarget(url: hub.url.toString(), keys: freshKeys);
    expect(hub.hellosSeen, 2); // initial + live generation

    proxy.release(); // parked cycle's socket completes NOW — it is stale
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(hub.hellosSeen, 2, reason: 'a superseded cycle must not hello');
    expect(client.agentId, id);

    // Receipts still flow on the live generation (the reported symptom:
    // sends fine, receives nothing).
    final peer = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    await peer.connect();
    await peer.sendDm(id, 'after release');
    final inbound =
        await client.inbound.first.timeout(const Duration(seconds: 2));
    expect(inbound.plaintext, 'after release');

    await peer.disconnect();
    await client.disconnect();
    await proxy.stop();
  }, timeout: timeout);

  test('an undecryptable inbound DM surfaces a marker, never silence',
      () async {
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    await client.connect();
    final sender = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
    );
    await sender.connect(); // registered, so whois(from) resolves

    final repository = HubMessagingRepository(client);
    await repository.start();
    hub.pushMsg(client.agentId!, {
      'from': sender.agentId,
      'to': client.agentId,
      'id': 'stale-1',
      'ts': 1,
      'ciphertext': 'AAAA', // garbage AEAD payload
    });
    await client.inbound.first.timeout(const Duration(seconds: 2));
    final drained = await repository.drain(client.agentId!);
    expect(drained, hasLength(1));
    expect(drained.single.text, contains('undecryptable'));

    await sender.disconnect();
    await client.disconnect();
  }, timeout: timeout);
}
