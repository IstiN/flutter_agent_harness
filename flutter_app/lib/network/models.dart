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
    this.isPublic = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String ownerId;
  final List<String>? admins;
  final List<String> publicChannels;

  /// Listed in the public-networks directory (`GET /api/networks/public`)
  /// — "public" is a catalog listing, NOT open join (the password is
  /// still required). Owner/admin toggles it via `PATCH .../networks/{id}`.
  final bool isPublic;
  final DateTime? createdAt;

  factory Network.fromJson(Map<String, Object?> json) => Network(
    id: _str(json['id']),
    name: _str(json['name']),
    ownerId: _str(json['ownerId']),
    admins: _strList(json['admins']),
    publicChannels: _strList(json['publicChannels']) ?? const [],
    isPublic: _bool(json['public']),
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

/// The one-time agent enrollment credential returned by
/// `POST /api/networks/{id}/agents/enroll` (owner/admin only). The
/// [clientSecret] is name-bound (the agent's dap/1 hello name MUST equal
/// [name]) and is returned EXACTLY ONCE — it is never stored server-side
/// and never returned again; re-enrolling the same name silently ROTATES
/// it (the old secret dies).
final class AgentEnrollment {
  const AgentEnrollment({
    required this.name,
    required this.hubUrl,
    required this.clientSecret,
    required this.enrolledAt,
    this.note,
  });

  /// The enrolled agent name (`^[a-z0-9][a-z0-9-]{2,63}$`).
  final String name;

  /// The DAP hub URL the agent connects to (e.g. `wss://hub.fa1.dev/ws`).
  final String hubUrl;

  /// The one-time client secret (`sk_…`) — copy it now or lose it.
  final String clientSecret;

  /// The enrollment timestamp (RFC 3339 UTC).
  final String enrolledAt;

  /// The server's storage/rotation note (informational).
  final String? note;

  /// Tolerant parse: everything defaults to empty/null so interim server
  /// shapes never break the client.
  factory AgentEnrollment.fromJson(Map<String, Object?> json) =>
      AgentEnrollment(
        name: _str(json['name']),
        hubUrl: _str(json['hubUrl']),
        clientSecret: _str(json['clientSecret']),
        enrolledAt: _str(json['enrolledAt']),
        note: _strOrNull(json['note']),
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
    this.senderKey,
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

  /// The sender's current X25519 pubkey (base64, directory metadata per
  /// the contract — never message content). Absent = unknown; fall back
  /// to a self-describing payload wrapper (fanet1) or whois.
  final String? senderKey;
  final DateTime? createdAt;

  factory Envelope.fromJson(Map<String, Object?> json) => Envelope(
    id: _str(json['id']),
    channelId: _str(json['channelId']),
    senderId: _str(json['senderId']),
    payload: _str(json['payload']),
    mentions: _strList(json['mentions']),
    senderKey: _strOrNull(json['senderKey']),
    createdAt: _date(json['createdAt']),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'channelId': channelId,
    'senderId': senderId,
    'payload': payload,
    'mentions': ?mentions,
    'senderKey': ?senderKey,
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

/// One entry of the public-networks directory (`GET /api/networks/public`
/// — deployed contract, issue #955 iteration 2). Items carry exactly four
/// fields (`id`, `name`, `publicChannels`, `memberCount` — the latter two
/// are INTs, no passwords/ownerId); parsing stays tolerant: only [id] and
/// [name] are required so interim server shapes never break the client.
/// The anonymous showcase listing of a public network
/// (`GET /api/networks/{id}/showcase`): its public channels, readable
/// without join or password.
final class Showcase {
  const Showcase({
    required this.id,
    required this.name,
    required this.channels,
  });

  factory Showcase.fromJson(Map<String, Object?> json) => Showcase(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    channels: [
      for (final c in (json['channels'] as List? ?? const []))
        if (c is Map)
          Channel(
            id: c['id'] as String? ?? '',
            networkId: json['id'] as String? ?? '',
            name: c['name'] as String?,
            isPublic: true,
          ),
    ],
  );

  final String id;
  final String name;
  final List<Channel> channels;
}

class PublicNetworkInfo {
  const PublicNetworkInfo({
    required this.id,
    required this.name,
    this.publicChannelCount,
    this.memberCount,
  });

  final String id;
  final String name;

  /// Number of public channels (wire: `publicChannels` as an int count).
  final int? publicChannelCount;

  /// Member count, when the server reports it.
  final int? memberCount;

  factory PublicNetworkInfo.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) {
      throw FormatException(
        'PublicNetworkInfo: "id" and "name" are required strings',
        json,
      );
    }
    return PublicNetworkInfo(
      id: id,
      name: name,
      publicChannelCount: _intOrNull(json['publicChannels']),
      memberCount: _intOrNull(json['memberCount']),
    );
  }
}

/// An OAuth token set from the ai-native auth endpoints (issue #955,
/// iteration 3): `POST /api/oauth-proxy/exchange` and
/// `POST /api/auth/refresh` answer in the dmtools form
/// `{accessToken, refreshToken, expiresIn, refreshExpiresIn,
/// tokenType: "Bearer"}`. The relative `expiresIn` seconds are folded
/// into absolute UTC instants at parse time ([now] is the test seam).
final class TokenBundle {
  const TokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.refreshExpiresAt,
  });

  /// The bearer access token (the ai-native JWT).
  final String accessToken;

  /// The refresh token for `POST /api/auth/refresh`.
  final String refreshToken;

  /// When [accessToken] expires (UTC).
  final DateTime expiresAt;

  /// When [refreshToken] expires (UTC); null = no server-declared limit.
  final DateTime? refreshExpiresAt;

  /// Tolerant parse: throws [FormatException] when the token strings are
  /// missing, treats absent/malformed lifetimes as 0 seconds. Accepts BOTH
  /// the snake_case the auth service actually returns
  /// (`access_token`/`expires_in` — see IstiN/auth OAuthExchange) and the
  /// camelCase the fa_network docs name.
  factory TokenBundle.fromJson(Map<String, Object?> json, {DateTime? now}) {
    final accessToken = json['accessToken'] ?? json['access_token'];
    final refreshToken = json['refreshToken'] ?? json['refresh_token'];
    if (accessToken is! String || refreshToken is! String) {
      throw FormatException(
        'TokenBundle: "accessToken"/"refreshToken" are required strings',
        json,
      );
    }
    final base = now ?? DateTime.now();
    final expiresIn = switch (json['expiresIn'] ?? json['expires_in']) {
      final num n => n.toInt(),
      _ => 0,
    };
    final refreshExpiresIn = switch (json['refreshExpiresIn'] ??
        json['refresh_expires_in']) {
      final num n => n.toInt(),
      _ => null,
    };
    return TokenBundle(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: base.add(Duration(seconds: expiresIn)).toUtc(),
      refreshExpiresAt: refreshExpiresIn != null
          ? base.add(Duration(seconds: refreshExpiresIn)).toUtc()
          : null,
    );
  }
}

/// The signed-in ai-native account profile (`GET /api/auth/user`,
/// issue #955 iteration 3). [name] is the display name (the wire's
/// `name` field); [email] doubles as the account login.
final class AuthProfile {
  const AuthProfile({
    required this.id,
    required this.email,
    required this.name,
    this.pictureUrl,
    this.provider,
  });

  /// The account id (wire: `id`).
  final String id;

  /// The account email — the sidebar/login label.
  final String email;

  /// The display name (wire: `name`).
  final String name;

  /// Avatar URL, when the provider reports one.
  final String? pictureUrl;

  /// The OAuth provider the account signed in through.
  final String? provider;

  /// Tolerant parse: everything defaults to empty/null so interim server
  /// shapes never break the client; a profile with neither [name] nor
  /// [email] is meaningless, so that case throws a [FormatException].
  factory AuthProfile.fromJson(Map<String, Object?> json) {
    final id = _str(json['id']);
    final email = _str(json['email']);
    final name = _str(json['name']);
    if (name.isEmpty && email.isEmpty) {
      throw FormatException(
        'AuthProfile: "name" and "email" are both missing',
        json,
      );
    }
    return AuthProfile(
      id: id,
      email: email,
      name: name.isNotEmpty ? name : email,
      pictureUrl: _strOrNull(json['pictureUrl']),
      provider: _strOrNull(json['provider']),
    );
  }
}
