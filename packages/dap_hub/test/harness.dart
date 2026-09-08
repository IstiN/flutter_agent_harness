// Shared test infrastructure: in-process hub over a real loopback
// HttpServer, real WebSocket dials, deterministic helpers (deadline
// reads, synchronous round-trips — no sleep-based sync).
//
// Port of the Go harness_test.go.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:crypto/crypto.dart' hide Hmac;
import 'package:cryptography/cryptography.dart';
import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';
import 'package:dap_hub/src/canonical_json.dart';
import 'package:dap_hub/src/crypto_utils.dart';
import 'package:test/test.dart';

const adminTestToken = 'test-admin-token';
const testMasterSecret = 'test-master-secret';

/// One running hub + server + captured log lines.
final class TestHub {
  TestHub._(this.hub, this.server, this.logLines);

  final DapHub hub;
  final DapHubServer server;
  final List<String> logLines;

  String get url => server.url;

  Future<void> close() => server.close();
}

/// Starts a hub with an injectable clock (tests steer time via [clock]).
Future<TestHub> startTestHub({
  String masterSecret = testMasterSecret,
  String adminToken = adminTestToken,
  HubStore? channelStore,
  HubStore? secretStore,
  TestClock? clock,
  Duration pingInterval = const Duration(hours: 1),
}) async {
  final lines = <String>[];
  final c = clock ?? TestClock();
  final hub = DapHub(
    config: DapHubConfig(
      masterSecret: masterSecret,
      adminToken: adminToken,
      channelStore: channelStore,
      secretStore: secretStore,
    ),
    nowMs: c.nowMs,
    log: lines.add,
  );
  await hub.load();
  final server = await DapHubServer.start(
    hub,
    port: 0,
    pingInterval: pingInterval,
  );
  return TestHub._(hub, server, lines);
}

/// A steered clock: starts at real now; [advance] jumps it forward.
final class TestClock {
  int _now = DateTime.now().millisecondsSinceEpoch;

  int nowMs() => _now;

  void advance(Duration d) => _now += d.inMilliseconds;
}

/// A client identity: an Ed25519 signing keypair plus (optionally) a
/// dedicated X25519 keypair for E2E (per DAP/1: separate keys).
final class TestAgent {
  TestAgent._(this.keyPair, this.pubB64, this.id, this.name);

  final SimpleKeyPair keyPair;
  final String pubB64;
  final String id;
  final String name;
  SimpleKeyPair? e2eKeyPair;
  String? e2ePubB64;

  static Future<TestAgent> create(String name) async {
    final keyPair = await Ed25519().newKeyPair();
    final pub = await keyPair.extractPublicKey();
    return TestAgent._(
      keyPair,
      base64.encode(pub.bytes),
      agentIdFor(pub.bytes),
      name,
    );
  }

  Future<void> withE2E() async {
    e2eKeyPair = await X25519().newKeyPair();
    final pub = await e2eKeyPair!.extractPublicKey();
    e2ePubB64 = base64.encode(pub.bytes);
  }
}

/// Signs [map] exactly as an adapter does: `sig` over
/// `dap1|op|ts|hex(sha256(canonical(frame minus sig)))`.
Future<Map<String, Object?>> signFrame(
  TestAgent agent,
  Map<String, Object?> map,
) async {
  final clone = Map<String, Object?>.of(map)..remove('sig');
  final sum = sha256.convert(utf8.encode(canonicalJson(clone)));
  final payload = 'dap1|${map['op']}|${map['ts']}|$sum';
  final sig = await Ed25519().sign(
    utf8.encode(payload),
    keyPair: agent.keyPair,
  );
  clone['sig'] = base64.encode(sig.bytes);
  return clone;
}

/// One dialed WebSocket with a frame queue.
final class TestConn {
  TestConn._(this.socket, this._queue);

  final WebSocket socket;
  final StreamQueue<Object> _queue;

  void writeJson(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  Future<void> writeSigned(
    TestAgent agent,
    Map<String, Object?> frame,
  ) async =>
      socket.add(jsonEncode(await signFrame(agent, frame)));

  /// Reads the next frame within [timeout]; null on timeout or when the
  /// connection closed.
  Future<Map<String, Object?>?> read({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final event = await _queue.next.timeout(timeout);
      return jsonDecode(event as String) as Map<String, Object?>;
    } on TimeoutException {
      return null;
    } on StateError {
      return null; // stream closed — the connection is gone
    }
  }

  /// First frame satisfying [want]; ops in [skip] are tolerated while
  /// waiting (presence broadcasts interleave with replies).
  Future<Map<String, Object?>> readUntil(
    bool Function(Map<String, Object?> frame) want, {
    List<String> skip = const [],
  }) async {
    for (var i = 0; i < 200; i++) {
      final frame = await read();
      if (frame == null) fail('read timed out waiting for a frame');
      if (want(frame)) return frame;
      final op = '${frame['op'] ?? frame['t'] ?? ''}';
      if (!skip.contains(op)) {
        fail('unexpected frame $frame (wanted one matching; skip=$skip)');
      }
    }
    fail('no matching frame arrived');
  }

  Future<Map<String, Object?>> readOp(String op,
          {List<String> skip = const ['presence']}) =>
      readUntil((f) => f['op'] == op, skip: skip);

  /// Asserts no frame arrives within [window] (deadline-based negative
  /// check — never a sleep-based sync).
  Future<void> expectQuiet([
    Duration window = const Duration(milliseconds: 200),
  ]) async {
    final frame = await read(timeout: window);
    if (frame != null) fail('unexpected frame $frame');
  }

  Future<void> close() async {
    await _queue.cancel(immediate: true);
    await socket.close();
  }
}

/// Dials /ws. [bearer] overrides the default master-secret header: pass
/// '' for no Authorization header at all (401 path), or a full secret to
/// dial as an enrolled agent.
Future<TestConn> dial(TestHub hub, {String? bearer}) async {
  final headers = <String, dynamic>{};
  final token = bearer ?? testMasterSecret;
  if (token.isNotEmpty) {
    headers['authorization'] = 'Bearer $token';
  }
  final socket = await WebSocket.connect(hub.url, headers: headers);
  return TestConn._(socket, StreamQueue<Object>(socket.cast<Object>()));
}

Map<String, Object?> helloMap(TestAgent agent) => {
      'op': 'hello',
      'v': 1,
      'pubkey': agent.pubB64,
      'name': agent.name,
      'nonce': randHex(),
      'ts': DateTime.now().millisecondsSinceEpoch,
      if (agent.e2ePubB64 != null) 'x25519': agent.e2ePubB64,
    };

/// Dials, performs hello, asserts the welcome agentId.
Future<TestConn> connect(TestHub hub, TestAgent agent, {String? bearer}) async {
  final conn = await dial(hub, bearer: bearer);
  await conn.writeSigned(agent, helloMap(agent));
  final welcome = await conn.readOp('welcome', skip: const []);
  expect(welcome['agentId'], agent.id, reason: 'welcome agentId');
  return conn;
}

Future<void> joinChan(
  TestConn conn,
  TestAgent agent,
  String channel, [
  String chanPubkey = 'chan-pub',
]) async {
  await conn.writeSigned(agent, {
    'op': 'join',
    'channel': channel,
    'chanPubkey': chanPubkey,
    'ts': DateTime.now().millisecondsSinceEpoch,
  });
  await conn.readOp('joined');
}

Future<void> sendChan(
  TestConn conn,
  TestAgent agent,
  String channel,
  String id,
  String ciphertext,
) =>
    conn.writeSigned(agent, {
      'op': 'send',
      'channel': channel,
      'id': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'ciphertext': ciphertext,
    });

Future<void> sendDM(
  TestConn conn,
  TestAgent agent,
  String to,
  String id,
  String ciphertext,
) =>
    conn.writeSigned(agent, {
      'op': 'send',
      'to': to,
      'id': id,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'ciphertext': ciphertext,
    });

Future<Map<String, Object?>> whois(TestConn conn, String agentId) async {
  conn.writeJson({'op': 'whois', 'agentId': agentId});
  return conn.readOp('agent_info');
}

/// Polls whois (a synchronous round trip) until the hub has processed
/// the target's disconnect — deterministic, no sleeps.
Future<void> waitOffline(TestConn conn, String agentId) async {
  for (var i = 0; i < 200; i++) {
    final info = await whois(conn, agentId);
    if (info['online'] == false) return;
  }
  fail('agent $agentId never went offline');
}

String randHex() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ---- E2E helpers (X25519 + HKDF-SHA256 + ChaCha20-Poly1305) ----

/// The payload key: HKDF-SHA256(ikm = x25519 ECDH secret, salt =
/// frame_id, info = "dap1/v1") → 32 bytes (spec §Crypto).
Future<SecretKey> e2eKey(
  SimpleKeyPair mine,
  String peerPubB64,
  String frameId,
) async {
  final peer = SimplePublicKey(
    base64.decode(peerPubB64),
    type: KeyPairType.x25519,
  );
  final shared = await X25519().sharedSecretKey(
    keyPair: mine,
    remotePublicKey: peer,
  );
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: utf8.encode(frameId),
    info: utf8.encode('dap1/v1'),
  );
}

/// Encrypts to base64(nonce(12) || ct || tag(16)) with the DAP/1 AAD.
Future<String> seal(
  SimpleKeyPair mine,
  String peerPubB64,
  String frameId,
  String aad,
  String plaintext,
) async {
  final key = await e2eKey(mine, peerPubB64, frameId);
  final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
  final box = await Chacha20.poly1305Aead().encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    nonce: nonce,
    aad: utf8.encode(aad),
  );
  return base64.encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

/// Decrypts base64(nonce(12) || ct || tag(16)).
Future<String> unseal(
  SimpleKeyPair mine,
  String peerPubB64,
  String frameId,
  String aad,
  String ciphertext,
) async {
  final key = await e2eKey(mine, peerPubB64, frameId);
  final raw = base64.decode(ciphertext);
  final clear = await Chacha20.poly1305Aead().decrypt(
    SecretBox(
      raw.sublist(12, raw.length - 16),
      nonce: raw.sublist(0, 12),
      mac: Mac(raw.sublist(raw.length - 16)),
    ),
    secretKey: key,
    aad: utf8.encode(aad),
  );
  return utf8.decode(clear);
}
