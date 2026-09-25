// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Wire models for the fa_network REST + WebSocket contract
/// (fa_network/docs/openapi.yaml). All models are immutable and parse
/// tolerantly: missing optional fields never throw and unknown enum wire
/// values degrade to an `unknown` fallback.
library;

/// Member class on the fa_network wire.
enum MemberClass {
  owner,
  admin,
  member,
  guest,
  agent,

  /// Forward-compatible fallback for classes this client does not know yet.
  unknown;

  /// Parses a wire value; anything unrecognized maps to [unknown].
  static MemberClass parse(Object? value) => switch (value) {
    'owner' => MemberClass.owner,
    'admin' => MemberClass.admin,
    'member' => MemberClass.member,
    'guest' => MemberClass.guest,
    'agent' => MemberClass.agent,
    _ => MemberClass.unknown,
  };
}

/// Presence of a member or agent on the wire.
enum Presence {
  live,
  busy,
  offline,

  /// Forward-compatible fallback for presences this client does not know yet.
  unknown;

  /// Parses a wire value; anything unrecognized maps to [unknown].
  static Presence parse(Object? value) => switch (value) {
    'live' => Presence.live,
    'busy' => Presence.busy,
    'offline' => Presence.offline,
    _ => Presence.unknown,
  };
}

String _str(Object? v) => v is String ? v : '';

String? _strOrNull(Object? v) => v is String ? v : null;

int? _intOrNull(Object? v) => switch (v) {
  int i => i,
  num n => n.toInt(),
  String s => int.tryParse(s),
  _ => null,
};

bool _bool(Object? v) => v == true;

bool? _boolOrNull(Object? v) => v is bool ? v : null;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String>? _strList(Object? v) =>
    v is List ? v.whereType<String>().toList() : null;

/// A fa_network network (no secrets).
class Network {
  const Network({
    required this.id,
    required this.name,
    required this.ownerId,
    this.admins,
    this.publicChannels = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final String ownerId;
  final List<String>? admins;
  final List<String> publicChannels;
  final DateTime? createdAt;

  factory Network.fromJson(Map<String, Object?> json) => Network(
    id: _str(json['id']),
    name: _str(json['name']),
    ownerId: _str(json['ownerId']),
    admins: _strList(json['admins']),
    publicChannels: _strList(json['publicChannels']) ?? const [],
    createdAt: _date(json['createdAt']),
  );
}

/// Out-of-band join credentials returned once by `POST /api/networks`.
class JoinCredentials {
  const JoinCredentials({this.networkId, this.password});

  final String? networkId;
  final String? password;

  factory JoinCredentials.fromJson(Map<String, Object?> json) =>
      JoinCredentials(
        networkId: _strOrNull(json['networkId']),
        password: _strOrNull(json['password']),
      );
}

/// A roster member (person or agent).
class Member {
  const Member({
    required this.id,
    required this.memberClass,
    required this.displayName,
    required this.presence,
  });

  final String id;
  final MemberClass memberClass;
  final String displayName;
  final Presence presence;

  factory Member.fromJson(Map<String, Object?> json) => Member(
    id: _str(json['id']),
    memberClass: MemberClass.parse(json['class']),
    displayName: _str(json['displayName']),
    presence: Presence.parse(json['presence']),
  );
}

/// A channel of a network. Message payloads stay opaque ciphertext.
class Channel {
  const Channel({
    required this.id,
    required this.networkId,
    this.name,
    this.isPublic = false,
    this.acl,
    this.retentionDays,
  });

  final String id;
  final String networkId;
  final String? name;

  /// Showcase mode: readable by everyone, writable by owner/admin only.
  final bool isPublic;

  /// dap channel ACL member ids (pubkey identities).
  final List<String>? acl;

  /// Optional per-channel envelope retention; `0` keeps nothing beyond live
  /// relay; null keeps until the network-level inactivity wipe.
  final int? retentionDays;

  factory Channel.fromJson(Map<String, Object?> json) => Channel(
    id: _str(json['id']),
    networkId: _str(json['networkId']),
    name: _strOrNull(json['name']),
    isPublic: _bool(json['public']),
    acl: _strList(json['acl']),
    retentionDays: _intOrNull(json['retentionDays']),
  );
}

/// An agent known to a network (openapi names this `Agent`; renamed here to
/// avoid the clash with the app's own agent types).
class NetworkAgent {
  const NetworkAgent({
    required this.agentId,
    required this.displayName,
    required this.presence,
    this.wakeupRegistered,
  });

  final String agentId;
  final String displayName;
  final Presence presence;
  final bool? wakeupRegistered;

  factory NetworkAgent.fromJson(Map<String, Object?> json) => NetworkAgent(
    agentId: _str(json['agentId']),
    displayName: _str(json['displayName']),
    presence: Presence.parse(json['presence']),
    wakeupRegistered: _boolOrNull(json['wakeupRegistered']),
  );
}

/// A relayed message envelope. [payload] is base64 opaque E2E ciphertext.
class Envelope {
  const Envelope({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.payload,
    this.mentions,
    this.createdAt,
  });

  /// Client-generated UUID; the at-least-once dedup key.
  final String id;
  final String channelId;
  final String senderId;

  /// Base64 opaque E2E ciphertext.
  final String payload;

  /// Mentioned agent ids (identity metadata only; drives wake-ups).
  final List<String>? mentions;
  final DateTime? createdAt;

  factory Envelope.fromJson(Map<String, Object?> json) => Envelope(
    id: _str(json['id']),
    channelId: _str(json['channelId']),
    senderId: _str(json['senderId']),
    payload: _str(json['payload']),
    mentions: _strList(json['mentions']),
    createdAt: _date(json['createdAt']),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'channelId': channelId,
    'senderId': senderId,
    'payload': payload,
    '''mentions''': ?mentions,
    'createdAt': ?createdAt?.toIso8601String(),
  };
}

/// The identity returned by a successful join.
class JoinedIdentity {
  const JoinedIdentity({
    required this.id,
    required this.memberClass,
    required this.displayName,
    this.authName,
  });

  final String id;
  final MemberClass memberClass;
  final String displayName;

  /// Present for authed joiners (from the auth service).
  final String? authName;

  factory JoinedIdentity.fromJson(Map<String, Object?> json) => JoinedIdentity(
    id: _str(json['id']),
    memberClass: MemberClass.parse(json['class']),
    displayName: _str(json['displayName']),
    authName: _strOrNull(json['authName']),
  );
}

/// Result of `POST /api/networks/{id}/join`.
class JoinResult {
  const JoinResult({
    required this.sessionToken,
    required this.identity,
    this.network,
  });

  /// Bearer token for member routes + /ws. Memory only.
  final String sessionToken;
  final JoinedIdentity identity;
  final Network? network;

  factory JoinResult.fromJson(Map<String, Object?> json) => JoinResult(
    sessionToken: _str(json['sessionToken']),
    identity: json['identity'] is Map
        ? JoinedIdentity.fromJson(
            (json['identity']! as Map).cast<String, Object?>(),
          )
        : const JoinedIdentity(
            id: '',
            memberClass: MemberClass.unknown,
            displayName: '',
          ),
    network: json['network'] is Map
        ? Network.fromJson((json['network']! as Map).cast<String, Object?>())
        : null,
  );
}

/// One page of message history.
class MessagePage {
  const MessagePage({required this.items, this.nextCursor});

  final List<Envelope> items;

  /// Cursor for the next page; null when the history is exhausted.
  final String? nextCursor;

  factory MessagePage.fromJson(Map<String, Object?> json) => MessagePage(
    items: json['items'] is List
        ? (json['items']! as List)
              .whereType<Map>()
              .map((e) => Envelope.fromJson(e.cast<String, Object?>()))
              .toList()
        : const [],
    nextCursor: _strOrNull(json['nextCursor']),
  );
}

/// A wake-up webhook registration (the secret is never returned).
class WakeupRegistration {
  const WakeupRegistration({
    required this.url,
    required this.debounceSeconds,
    this.createdAt,
  });

  final String url;
  final int debounceSeconds;
  final DateTime? createdAt;

  factory WakeupRegistration.fromJson(Map<String, Object?> json) =>
      WakeupRegistration(
        url: _str(json['url']),
        debounceSeconds: _intOrNull(json['debounceSeconds']) ?? 0,
        createdAt: _date(json['createdAt']),
      );
}

/// One entry of the wake-up dispatch log.
class WakeupDispatch {
  const WakeupDispatch({
    required this.agentId,
    required this.at,
    required this.outcome,
    this.note,
  });

  final String agentId;
  final DateTime? at;

  /// `delivered` | `target_down` | `skipped_online` | `backoff`.
  final String outcome;
  final String? note;

  factory WakeupDispatch.fromJson(Map<String, Object?> json) => WakeupDispatch(
    agentId: _str(json['agentId']),
    at: _date(json['at']),
    outcome: _str(json['outcome']),
    note: _strOrNull(json['note']),
  );
}
