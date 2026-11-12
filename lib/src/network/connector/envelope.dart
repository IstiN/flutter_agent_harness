/// Network envelope v1 — the one-wire-frame model of the fa_network machine
/// connector (issue #2062, contract `docs/fa_network_connector.md` §3).
///
/// One JSON frame per WebSocket text message; every frame the connector and
/// the fake device server exchange is a [NetworkEnvelope]. The model is
/// PURE Dart (no `dart:io`, no Flutter) — native sockets live behind
/// `lib/io.dart` in a later slice; tests and hosts inject transports.
///
/// Contract shape (§3): `v`/`kind`/`msgId`/`refId`/`network`/`channel`/
/// `from`/`to`/`ts`/`seq`/`ciphertext`. Two documented additions beyond the
/// literal example frame: control-plane kinds (`hello`, `hello_ok`,
/// `presence`, `roster`, `wake_hint`, `error`) carry their plaintext data in
/// `payload` (deviceId, roster digest, presence states, wake hints — §4/§5/§8
/// mandate this data on non-mail frames), while `mail` stays ciphertext-only
/// per the relay-only invariant (§3/§11): the server never reads mail
/// content or keys.
library;

import 'dart:math';

/// The wire protocol version this library speaks (contract §3: `"v": 1`).
const int networkEnvelopeVersion = 1;

/// Prefix of a DM virtual channel id (contract §7: DM is a virtual channel
/// routed by `to`, not a channel object with members).
const String dmChannelPrefix = 'dm:';

/// Prefix of the full DM id form: `dm:user:<userId>:<agentName>@<deviceId>`.
const String dmChannelUserPrefix = 'dm:user:';

/// Joins an agent name and host device id into the contract §1 agent
/// address: `<agentName>@<deviceId>` (e.g. `goal_builder@macbook`).
String agentAddress(String agentName, String deviceId) =>
    '$agentName@$deviceId';

/// The stable DM channel id for a user ↔ agent pair (contract §7):
/// `dm:user:<userId>:<agentName>@<deviceId>`. Identical derived from both
/// ends, so the user client and the agent address the same virtual channel.
String dmChannelId(String userId, String agentAddressOf) =>
    '$dmChannelUserPrefix$userId:$agentAddressOf';

/// Whether [channel] is a DM virtual channel id (`dm:...`) rather than a
/// group channel id.
bool isDmChannel(String channel) => channel.startsWith(dmChannelPrefix);

/// Renders [timestamp] as the RFC3339 UTC stamp the contract uses for the
/// `ts` field (`2026-11-12T12:30:45.123Z` form).
String rfc3339Timestamp(DateTime timestamp) =>
    timestamp.toUtc().toIso8601String();

final Random _idRandom = Random.secure();

/// Mints a random UUIDv4 string — the default [IdFactory] for `msgId`s.
String defaultIdFactory() {
  final bytes = List<int>.generate(16, (_) => _idRandom.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  String hex(int index) => bytes[index].toRadixString(16).padLeft(2, '0');
  return '${_hexRange(hex, 0, 4)}-${_hexRange(hex, 4, 6)}-'
      '${_hexRange(hex, 6, 8)}-${_hexRange(hex, 8, 10)}-'
      '${_hexRange(hex, 10, 16)}';
}

String _hexRange(String Function(int) hex, int start, int end) =>
    [for (var i = start; i < end; i++) hex(i)].join();

/// Factory for wire ids (`msgId` on frames the connector mints). Injectable
/// so tests can assert exact ids.
typedef IdFactory = String Function();

/// The frame kinds of envelope v1 (contract §3). Wire names are the
/// snake_case forms the backend and the client both speak.
enum NetworkEnvelopeKind {
  /// Device → server on connect: deviceId + local roster digest (§4).
  hello('hello'),

  /// Server → device handshake answer; `refId` references the hello (§3).
  helloOk('hello_ok'),

  /// Mail: the only E2E-content frame; routed by (network, channel, to),
  /// deduped by `msgId`, persisted with a server-stamped `seq` (§3).
  mail('mail'),

  /// Presence: machine state rides device-level frames (no `network`),
  /// agent/session presence rides inside the machine frame (§5).
  presence('presence'),

  /// Roster snapshot or incremental patch for the device's networks (§4).
  roster('roster'),

  /// Delivery receipt: the connector acks inbound mail only AFTER the local
  /// mailbox write; `refId` references the delivered `msgId` (§3/§4).
  ack('ack'),

  /// Wake hint with an identity-only payload (`{type: ...}`, §8).
  wakeHint('wake_hint'),

  /// Heartbeat keepalive (~every 20 s); the server drops half-open
  /// connections that stop answering (§4).
  ping('ping'),

  /// The answer to a [ping].
  pong('pong'),

  /// Protocol error; `refId` references the offending frame (§3).
  error('error');

  const NetworkEnvelopeKind(this.wireName);

  /// The snake_case wire form (`hello_ok`, `wake_hint`).
  final String wireName;

  /// Parses a wire kind name; null for unknown kinds (decode rejects them).
  static NetworkEnvelopeKind? tryParse(String wireName) {
    for (final kind in values) {
      if (kind.wireName == wireName) return kind;
    }
    return null;
  }
}

/// One envelope-v1 frame (contract §3). Value type: [==] compares every
/// field so decoded frames match minted ones in tests.
final class NetworkEnvelope {
  /// Builds a frame. [msgId] and [ts] are mandatory on every kind; the rest
  /// is kind-dependent (see [validationErrors] for the per-kind rules).
  const NetworkEnvelope({
    required this.kind,
    required this.msgId,
    required this.ts,
    this.refId,
    this.network,
    this.channel,
    this.from,
    this.to,
    this.seq,
    this.ciphertext,
    this.payload = const {},
  }) : v = networkEnvelopeVersion;

  /// Wire protocol version — always [networkEnvelopeVersion] on minted
  /// frames; decode rejects anything else.
  final int v;

  /// The frame kind.
  final NetworkEnvelopeKind kind;

  /// Frame id. On `mail` frames this IS the fanet1 `frameId` (contract v1.1,
  /// §7): the HKDF salt, the AAD segment and the dedup key are all this one
  /// string — so offline retries MUST reuse the original id byte-for-byte
  /// (re-minting would break E2E decryption and server-side dedup).
  final String msgId;

  /// Referenced frame id: the delivered msgId on ack/error, the hello msgId
  /// on hello_ok. Required for those kinds ([validationErrors]).
  final String? refId;

  /// The network this frame belongs to. Absent on device-level frames
  /// (hello, machine presence). Required on mail.
  final String? network;

  /// The channel: a group channel id or a `dm:...` virtual channel id.
  /// Required on mail.
  final String? channel;

  /// Sender address: `<agentName>@<deviceId>` or `user:<aiNativeUserId>`.
  final String? from;

  /// Recipient address. Required on DM mail (`to` routes the virtual
  /// channel; §3/§7).
  final String? to;

  /// RFC3339 UTC stamp ([rfc3339Timestamp] renders minted values).
  final String ts;

  /// Server-stamped per-channel sequence number on persisted mail (§3).
  /// Absent on frames the connector mints.
  final int? seq;

  /// The opaque fanet1 ciphertext. Mail-only (relay-only invariant §3/§11:
  /// the server never reads it; connector-side decoding is an injectable
  /// seam, DM crypto rides a later slice).
  final String? ciphertext;

  /// Plaintext control-plane data for NON-mail kinds: hello deviceId +
  /// roster digest (§4), presence states (§5), roster snapshot (§4), wake
  /// hints (§8), error messages. Empty on mail frames.
  final Map<String, Object?> payload;

  /// Structural decode: builds a frame from wire JSON. Throws
  /// [FormatException] on a non-map body, missing `msgId`, unknown `kind`
  /// or a version other than 1; everything else is tolerant (unknown keys
  /// are ignored — forward compatibility).
  factory NetworkEnvelope.fromJson(Object? json) {
    if (json is! Map) {
      throw FormatException('envelope must be a JSON object, got $json');
    }
    final version = json['v'];
    if (version is! int || version != networkEnvelopeVersion) {
      throw FormatException('unsupported envelope version: $version');
    }
    final wireKind = json['kind'];
    final kind = NetworkEnvelopeKind.tryParse(wireKind as String? ?? '');
    if (kind == null) {
      throw FormatException('unknown envelope kind: $wireKind');
    }
    final msgId = json['msgId'];
    if (msgId is! String || msgId.isEmpty) {
      throw FormatException('envelope msgId must be a non-empty string');
    }
    return NetworkEnvelope(
      kind: kind,
      msgId: msgId,
      refId: _stringOrNull(json['refId']),
      network: _stringOrNull(json['network']),
      channel: _stringOrNull(json['channel']),
      from: _stringOrNull(json['from']),
      to: _stringOrNull(json['to']),
      ts: _stringOrNull(json['ts']) ?? '',
      seq: json['seq'] is int ? json['seq'] as int : null,
      ciphertext: _stringOrNull(json['ciphertext']),
      payload: json['payload'] is Map
          ? Map<String, Object?>.from(json['payload'] as Map)
          : const {},
    );
  }

  /// Decode + validate in one step: throws [EnvelopeValidationException]
  /// when the decoded frame violates the per-kind rules of [validationErrors].
  factory NetworkEnvelope.parseValid(Object? json) {
    final envelope = NetworkEnvelope.fromJson(json);
    envelope.requireValid();
    return envelope;
  }

  /// Wire JSON: fixed key order mirroring the contract §3 example; null
  /// optionals are omitted; [payload] is written only when non-empty.
  Map<String, Object?> toJson() => {
    'v': v,
    'kind': kind.wireName,
    'msgId': msgId,
    if (refId != null) 'refId': refId,
    if (network != null) 'network': network,
    if (channel != null) 'channel': channel,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    'ts': ts,
    if (seq != null) 'seq': seq,
    if (ciphertext != null) 'ciphertext': ciphertext,
    if (payload.isNotEmpty) 'payload': payload,
  };

  /// Per-kind semantic validation (contract §3):
  /// - `mail` requires `network`, `channel` and `ciphertext`; DM mail
  ///   (`dm:...` channel) additionally requires `to`;
  /// - `ack`, `error`, `hello_ok` require `refId`;
  /// - `hello` requires a non-empty `deviceId` in [payload].
  ///
  /// The per-kind checks live in dedicated getters (each a small
  /// complexity unit — the crap4dart CRAP ratchet caps per-method
  /// complexity), dispatched by kind here.
  List<String> get validationErrors {
    final problems = <String>[if (msgId.isEmpty) 'msgId must be non-empty'];
    return problems..addAll(_kindSpecificErrors);
  }

  /// The kind's own validation contribution (empty for ping/pong).
  List<String> get _kindSpecificErrors => switch (kind) {
    NetworkEnvelopeKind.mail => _mailErrors,
    NetworkEnvelopeKind.ack ||
    NetworkEnvelopeKind.error ||
    NetworkEnvelopeKind.helloOk => _refIdErrors,
    NetworkEnvelopeKind.hello => _helloErrors,
    NetworkEnvelopeKind.presence ||
    NetworkEnvelopeKind.roster ||
    NetworkEnvelopeKind.wakeHint => _payloadErrors,
    NetworkEnvelopeKind.ping || NetworkEnvelopeKind.pong => const <String>[],
  };

  /// `mail` frame requirements (contract §3). Null checks lift into
  /// locals (repo convention: no `!` on nullable fields).
  List<String> get _mailErrors {
    final net = network;
    final chan = channel;
    final dst = to;
    final body = ciphertext;
    return <String>[
      if (net == null || net.isEmpty) 'mail requires network',
      if (chan == null || chan.isEmpty) 'mail requires channel',
      if (chan != null && isDmChannel(chan) && (dst == null || dst.isEmpty))
        'dm mail requires to',
      if (body == null || body.isEmpty) 'mail requires ciphertext',
    ];
  }

  /// Ack-family frames reference a delivered msgId via `refId`.
  List<String> get _refIdErrors {
    final ref = refId;
    return <String>[if (ref == null || ref.isEmpty) '$kind requires refId'];
  }

  /// `hello` carries the enrolling device identity in its payload.
  List<String> get _helloErrors {
    final deviceId = payload['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      return <String>['hello requires payload deviceId'];
    }
    return const <String>[];
  }

  /// Presence-family frames carry their state map in `payload`.
  List<String> get _payloadErrors => <String>[
    if (payload.isEmpty) '$kind requires payload',
  ];

  /// True when [validationErrors] is empty.
  bool get isValid => validationErrors.isEmpty;

  /// Throws [EnvelopeValidationException] carrying every problem, or a
  /// no-op on a valid frame.
  void requireValid() {
    final problems = validationErrors;
    if (problems.isNotEmpty) {
      throw EnvelopeValidationException(msgId: msgId, problems: problems);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkEnvelope && _sameEnvelope(other);

  /// Field comparison split across small helpers (the CRAP ratchet
  /// caps per-method complexity; a 13-field `&&` chain exceeds it).
  bool _sameEnvelope(NetworkEnvelope other) =>
      v == other.v &&
      kind == other.kind &&
      _sameRoute(other) &&
      _sameCore(other) &&
      _mapEquals(other.payload, payload);

  /// Routing fields (contract §3: network/channel/to + ack reference).
  bool _sameRoute(NetworkEnvelope other) =>
      msgId == other.msgId &&
      refId == other.refId &&
      network == other.network &&
      channel == other.channel &&
      to == other.to;

  /// Content fields (sender, timing, payload bytes).
  bool _sameCore(NetworkEnvelope other) =>
      from == other.from &&
      ts == other.ts &&
      seq == other.seq &&
      ciphertext == other.ciphertext;

  @override
  int get hashCode => Object.hash(
    v,
    kind,
    msgId,
    refId,
    network,
    channel,
    from,
    to,
    ts,
    seq,
    ciphertext,
    Object.hashAll(payload.keys),
    Object.hashAll(payload.values),
  );

  @override
  String toString() {
    final route = [
      if (network != null) network,
      if (channel != null) channel,
      if (to != null) 'to=$to',
    ].join('/');
    final cipher = ciphertext;
    return 'NetworkEnvelope(${kind.wireName} $route msgId=$msgId'
        '${seq == null ? '' : ' seq=$seq'}'
        '${cipher == null ? '' : ' ciphertext:<${cipher.length} bytes>'}'
        '${payload.isEmpty ? '' : ' payload:$payload'})';
  }
}

String? _stringOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Semantic envelope violation: the frame decodes but breaks the §3 per-kind
/// rules. Carries every problem at once so diagnostics point at all faults.
final class EnvelopeValidationException implements Exception {
  EnvelopeValidationException({required this.msgId, required this.problems});

  /// The offending frame's id.
  final String msgId;

  /// Every validation problem found.
  final List<String> problems;

  @override
  String toString() =>
      'EnvelopeValidationException(msgId=$msgId: ${problems.join('; ')})';
}
