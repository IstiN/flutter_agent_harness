/// Browser bridge wire protocol v1 (issue #23) — the pure-Dart half shared
/// by the loopback server (`bin/serve_bridge.dart`), tests, and tooling.
///
/// One JSON object per WebSocket text frame:
///
/// ```json
/// {"v":1,"id":"<frameId>","op":"...","...":...}
/// ```
///
/// See `docs` / the cross-slice contract for the op table. Everything here
/// is pure Dart: no dart:io, safe for web consumers. The transport (HTTP
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../messaging/file_messaging_repository.dart';

/// The only protocol version this build speaks. A mismatching envelope `v`
/// (or hello `proto`) is rejected with [BridgeErrorCode.proto].
const int bridgeProtocolVersion = 1;

/// Default TCP port of the loopback bridge (`fa serve --bridge`).
const int bridgeDefaultPort = 8777;

/// The single WebSocket endpoint served by the bridge.
const String bridgeWsPath = '/ws';

/// Payload key carrying the browser op name inside a `browserReq` frame.
/// The envelope `op` is `browserReq` itself, so the browser op cannot ride
/// the same key (JSON objects have flat, unique keys); the contract's
/// `browserReq {id, op, args}` maps `id` → envelope id and `op` → this
/// field.
const String bridgeBrowserOpField = 'req';

/// WebSocket close code used when the pairing token is rejected.
const int bridgeBadTokenCloseCode = 4401;

/// Fabric mailbox namespace for paired extensions: `browser-ext/<agentId>`.
const String bridgeMailboxPrefix = 'browser-ext/';

/// How long a [BridgeConnection.dispatch] waits for the correlated
/// `browserRes` before resolving with a timeout error result.
const Duration bridgeDispatchTimeout = Duration(seconds: 30);

/// Fabric mailbox poll interval while an extension is connected.
const Duration bridgePollInterval = Duration(seconds: 1);

/// Fabric heartbeat (`messaging.touch`) interval while connected — keeps the
/// mailbox live in [directory views](formatA2aStatusLines-style listings).
const Duration bridgeHeartbeatInterval = Duration(seconds: 5);

/// Bounded dedupe window: at most this many message ids are remembered
/// (LRU — re-seeing an old id after eviction forwards it again).
const int bridgeDedupeCapacity = 512;

/// Client → server and server → client op names (the full v1 set).
abstract final class BridgeOps {
  /// Pairing handshake. First frame on every connection.
  static const hello = 'hello';

  /// Handshake reply: mailbox, server label, capabilities.
  static const welcome = 'welcome';

  /// Mail relay, both directions.
  static const mail = 'mail';

  /// Server ack for a delivered `mail` (envelope id echoes the mail frame).
  static const acked = 'acked';

  /// Keepalive.
  static const ping = 'ping';

  /// Keepalive reply (envelope id echoes the ping).
  static const pong = 'pong';

  /// Server → extension browser control request.
  static const browserReq = 'browserReq';

  /// Extension → server reply, correlated by the `id` field.
  static const browserRes = 'browserRes';

  /// Envelope-level rejection (bad token, unknown op, malformed frame).
  static const error = 'error';
}

/// Every op a v1 peer may send; anything else decodes fine but is answered
/// with [BridgeErrorCode.badOp].
const Set<String> bridgeKnownOps = {
  BridgeOps.hello,
  BridgeOps.welcome,
  BridgeOps.mail,
  BridgeOps.acked,
  BridgeOps.ping,
  BridgeOps.pong,
  BridgeOps.browserReq,
  BridgeOps.browserRes,
  BridgeOps.error,
};

/// Wire error codes. Envelope-level codes ([proto], [badToken], [badFrame],
/// [badOp]) travel on `error` frames; the rest are browser-op results
/// carried inside `browserRes` payloads.
enum BridgeErrorCode {
  /// Envelope/hello protocol-version mismatch (reply + close).
  proto('proto'),

  /// Pairing token wrong or absent (reply + close 4401).
  badToken('bad_token'),

  /// Frame is not a JSON object, or misses `v`/`id`/`op`.
  badFrame('bad_frame'),

  /// Well-formed frame with an op this peer does not handle.
  badOp('bad_op'),

  /// Browser op gave up (dispatch timeout, page wait elapsed).
  timeout('timeout'),

  /// Browser op refused by policy.
  denied('denied'),

  /// No connected extension to route the request to.
  noTarget('no_target'),

  /// Browser op called with missing/invalid args.
  badArgs('bad_args'),

  /// Selector matched nothing (vanished between read and act).
  nodeVanished('node_vanished'),

  /// No tab available for the op.
  noTab('no_tab'),

  /// chrome://, Web Store, PDF — not automatable.
  restrictedPage('restricted_page'),

  /// Page CSP blocked the injection.
  csp('csp');

  const BridgeErrorCode(this.wire);

  /// The exact string on the wire (snake_case, contract-pinned).
  final String wire;

  /// Parses a wire code; null when the peer invented one.
  static BridgeErrorCode? fromWire(String wire) {
    for (final code in values) {
      if (code.wire == wire) return code;
    }
    return null;
  }
}

/// A protocol violation found while decoding a frame. The transport answers
/// with an `error` frame (and closes for [BridgeErrorCode.proto]).
final class BridgeProtocolException implements Exception {
  const BridgeProtocolException(this.code, this.message, {this.inReplyTo});

  /// What went wrong.
  final BridgeErrorCode code;

  /// Human-readable detail for the error frame.
  final String message;

  /// The offending frame's id, when it carried a parsable one.
  final String? inReplyTo;

  @override
  String toString() => 'bridge: ${code.wire}: $message';
}

/// One decoded wire frame. `v`/`id`/`op` are pulled out of [fields]; the
/// rest of the payload stays addressable there.
final class BridgeFrame {
  BridgeFrame({
    required this.id,
    required this.op,
    Map<String, dynamic>? fields,
  }) : fields = fields ?? const {};

  /// Correlation id: echoed by replies (`pong`/`acked`/`welcome`/`error`),
  /// fresh per request (`mail`, `browserReq`).
  final String id;

  /// The op name ([BridgeOps]).
  final String op;

  /// Remaining payload fields (without `v`/`id`/`op`).
  final Map<String, dynamic> fields;

  /// Wire form: payload fields first, then the envelope keys — `v`/`id`/
  /// `op` are RESERVED: a payload field reusing one is shadowed on the
  /// wire, never allowed to corrupt the envelope.
  Map<String, dynamic> toJson() => {
    ...fields,
    'v': bridgeProtocolVersion,
    'id': id,
    'op': op,
  };

  /// Encodes to the JSON text sent over the WebSocket.
  String encode() => jsonEncode(toJson());

  /// Strict decode: throws [BridgeProtocolException] on a non-JSON-object
  /// body or a missing/mismatching `v`/`id`/`op`. Unknown ops decode fine —
  /// the caller answers those with [BridgeErrorCode.badOp].
  static BridgeFrame decode(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const BridgeProtocolException(
        BridgeErrorCode.badFrame,
        'frame is not valid JSON',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BridgeProtocolException(
        BridgeErrorCode.badFrame,
        'frame is not a JSON object',
      );
    }
    if (decoded['v'] != bridgeProtocolVersion) {
      throw BridgeProtocolException(
        BridgeErrorCode.proto,
        'unsupported protocol version: ${decoded['v']}',
        inReplyTo: decoded['id'] is String ? decoded['id'] as String : null,
      );
    }
    final id = decoded['id'];
    final op = decoded['op'];
    if (id is! String || id.isEmpty) {
      throw const BridgeProtocolException(
        BridgeErrorCode.badFrame,
        'missing frame id',
      );
    }
    if (op is! String || op.isEmpty) {
      throw BridgeProtocolException(
        BridgeErrorCode.badFrame,
        'missing op',
        inReplyTo: id,
      );
    }
    final fields = Map<String, dynamic>.from(decoded)
      ..remove('v')
      ..remove('id')
      ..remove('op');
    return BridgeFrame(id: id, op: op, fields: fields);
  }

  /// A string payload field, null when absent or not a string.
  String? str(String key) =>
      fields[key] is String ? fields[key] as String : null;

  /// An object payload field, null when absent or not an object.
  Map<String, dynamic>? map(String key) => fields[key] is Map<String, dynamic>
      ? fields[key] as Map<String, dynamic>
      : null;
}

final Random _secureRandom = Random.secure();

/// One-time pairing token: 32 secure random bytes as 64 lowercase hex chars.
/// Minted fresh by every `/browser connect` — an old token stops working.
String pairingToken() => List.generate(
  32,
  (_) => _secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// 8 secure random hex chars — the fallback `<agentId>` when the extension
/// did not persist one (contract: `browser-ext/<agentId or random8>`).
String randomMailboxSuffix() => List.generate(
  4,
  (_) => _secureRandom.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Fabric mailbox id for a paired extension: `browser-ext/<agentId>`, the
/// agent id sanitized by the same rules every mailbox directory uses.
String deriveMailboxId(String agentId) =>
    '$bridgeMailboxPrefix${FileMessagingRepository.sanitizeAgentId(agentId)}';

/// Reconnect backoff for bridge clients: 1s doubling, capped at 30s.
///
/// Mirrors the DAP `HubClient.defaultBackoff` — the shift exponent is
/// clamped BEFORE shifting, because `1 << 64` is 0 under Dart's 64-bit
/// shift semantics and a huge attempt would otherwise collapse the delay to
/// zero (a tight reconnect loop).
Duration bridgeBackoff(int attempt) {
  final shift = (attempt - 1).clamp(0, 5);
  final seconds = 1 << shift;
  return seconds > 30
      ? const Duration(seconds: 30)
      : Duration(seconds: seconds);
}

/// Bounded LRU dedupe over fabric message ids: a re-observed id inside the
/// window is a duplicate (drop it); the oldest id falls out at capacity.
final class MailDeduper {
  MailDeduper({this.capacity = bridgeDedupeCapacity});

  /// Maximum remembered ids.
  final int capacity;

  /// LinkedHashSet: insertion-ordered, re-add moves the id to the newest
  /// slot — the LRU order falls out for free.
  final LinkedHashSet<String> _seen = LinkedHashSet();

  /// Records [msgId] and reports whether it was seen inside the window.
  bool isDuplicate(String msgId) {
    if (_seen.remove(msgId)) {
      _seen.add(msgId); // refresh: recently re-observed ids survive eviction
      return true;
    }
    _seen.add(msgId);
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return false;
  }
}

/// Frame correlation id: `<epochMs>-<8 hex rand>` — sortable by time,
/// collision-safe across peers.
String nextFrameId() {
  final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
  final rand =
      ((_secureRandom.nextInt(1 << 16) << 16) | _secureRandom.nextInt(1 << 16))
          .toRadixString(16)
          .padLeft(8, '0');
  return '$ms-${rand.substring(rand.length - 8)}';
}
