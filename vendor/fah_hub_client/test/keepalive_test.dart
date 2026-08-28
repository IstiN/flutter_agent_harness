/// Client resilience: keepalive (native dart:io `pingInterval` watchdog),
/// honest failure (send/dm while disconnected), hub error-frame surfacing.
///
/// The watchdog itself is VM-native (no injectable tick), so it is exercised
/// with short real intervals and event-driven awaits — the suite's existing
/// 5 ms-backoff style — never sleep-as-synchronization.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:fah_hub_client/fah_hub_client.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));
final tinyBackoff = (int _) => const Duration(milliseconds: 5);

const _wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// A hub that completes the WebSocket upgrade and then goes SILENT: it never
/// answers pings — the classic half-open connection (laptop sleep, NAT
/// timeout). Complements [FakeHub], whose dart:io server auto-pongs.
class SilentHub {
  ServerSocket? _server;
  int connections = 0;
  final _connEvents = StreamController<int>.broadcast();

  Future<void> start() async {
    _server = await ServerSocket.bind('127.0.0.1', 0);
    _server!.listen((socket) {
      connections++;
      if (!_connEvents.isClosed) _connEvents.add(connections);
      unawaited(_upgradeThenIgnore(socket));
    });
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  /// Resolves once [n] connections have been accepted (reconnect proof).
  Future<void> waitForConnections(int n) async {
    if (connections >= n) return;
    await _connEvents.stream
        .firstWhere((c) => c >= n)
        .timeout(const Duration(seconds: 5));
  }

  Future<void> _upgradeThenIgnore(Socket socket) async {
    final buf = <int>[];
    await for (final data in socket) {
      buf.addAll(data);
      final text = utf8.decode(buf, allowMalformed: true);
      if (!text.contains('\r\n\r\n')) return;
      final key = RegExp('sec-websocket-key: ([^\\r]+)', caseSensitive: false)
          .firstMatch(text)!
          .group(1)!;
      final accept =
          base64Encode((await Sha1().hash(utf8.encode(key + _wsGuid))).bytes);
      socket.add(utf8.encode(
          'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
          'Connection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n'));
      buf.clear(); // keep draining; never send anything again
    }
  }

  Future<void> stop() async {
    await _connEvents.close();
    await _server?.close();
  }
}

void main() {
  test('keepalive: silent peer (no pongs) is torn down; reconnect loop takes over',
      () async {
    final hub = SilentHub();
    await hub.start();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      backoff: tinyBackoff,
      pingInterval: const Duration(milliseconds: 150),
    );
    // No welcome will ever come; the loop future ends with disconnect().
    client.connect().ignore();
    try {
      // The native watchdog closes the zombie socket, the existing reconnect
      // loop dials again — observed as a SECOND accepted connection.
      await hub.waitForConnections(2);
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('keepalive: answering peer survives ping cycles and stays usable',
      () async {
    final hub = FakeHub();
    await hub.start();
    final seenHellos = <String>[];
    final sub = hub.hellos.listen(seenHellos.add);
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      pingInterval: const Duration(milliseconds: 60),
    );
    try {
      await client.connect();
      final id = client.agentId!;
      // Let several ping/pong cycles pass (~6 × 60 ms). FakeHub's dart:io
      // server answers pings, so a correct watchdog must NOT drop us.
      await Future<void>.delayed(const Duration(milliseconds: 380));
      expect(seenHellos.where((h) => h == id), hasLength(1),
          reason: 'live connection must not be recycled');
      // And the socket still carries traffic: DM to self round-trips.
      final got = client.inbound
          .firstWhere((m) => m.plaintext == 'still alive')
          .timeout(const Duration(seconds: 5));
      await client.sendDm(id, 'still alive');
      final msg = await got;
      expect(msg.from, id);
    } finally {
      await sub.cancel();
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);

  test('disconnect() disarms keepalive and reconnect machinery', () async {
    final hub = FakeHub();
    await hub.start();
    final seenHellos = <String>[];
    final sub = hub.hellos.listen(seenHellos.add);
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
      pingInterval: const Duration(milliseconds: 60),
    );
    try {
      await client.connect();
      final id = client.agentId!;
      final offline =
          hub.agentOffline.firstWhere((a) => a == id).timeout(tinyBackoff(1));
      await client.disconnect();
      await offline;
      // Several ping cycles later: no watchdog-driven re-hello churn.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(seenHellos.where((h) => h == id), hasLength(1));
    } finally {
      await sub.cancel();
      await hub.stop();
    }
  }, timeout: timeout);

  test('honest failure: sendToChannel/sendDm while disconnected throw',
      () async {
    final client = HubClient(
      config: HubConfig(
        url: 'ws://127.0.0.1:1/ws', // nothing listens; never connected
        channels: {'general': base64Encode(List.filled(32, 1))},
      ),
      identity: await HubIdentity.generate(),
    );
    await expectLater(
        client.sendToChannel('general', 'anyone?'), throwsA(isA<StateError>()));
    await expectLater(
        client.sendDm('a_0123456789abcdef', 'anyone?'), throwsA(isA<StateError>()));
  }, timeout: timeout);

  test('error surfacing: hub error frame is exposed, never silent', () async {
    final hub = FakeHub();
    await hub.start();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
    );
    try {
      await client.connect();
      final first = client.errors.first.timeout(const Duration(seconds: 5));
      hub.pushError(client.agentId!, 'access_denied', 'channel key mismatch');
      final error = await first;
      expect(error.code, 'access_denied');
      expect(error.msg, 'channel key mismatch');
    } finally {
      await client.disconnect();
      await hub.stop();
    }
  }, timeout: timeout);
}
