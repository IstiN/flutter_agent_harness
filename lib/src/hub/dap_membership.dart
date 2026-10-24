// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Scoped DAP channel membership (issue #1825): one record shape for all
/// three scopes, and the union/dedup algebra the delivery layer rides on.
///
/// Scopes are blast-radius controls, widest last:
/// - [DapChannelScope.session] — a `dap_channel_membership` custom record
///   on the session JSONL tree (re-join on resume, dies with the branch);
/// - [DapChannelScope.project] — `.fah/dap.json` in the project root;
/// - [DapChannelScope.global] — the machine-wide `~/.dap` channel list.
///
/// Effective membership is the union deduped by `(hubUrl, channelId)`: the
/// same channel joined at two scopes delivers each frame ONCE, and leaving
/// one scope keeps the other alive.
library;

/// The three membership scopes, ordered narrowest → widest.
enum DapChannelScope { session, project, global }

/// One channel membership record. [pub]/[priv] are the channel X25519
/// keypair (base64) — null for a PUBLIC channel (keyless join).
///
/// At rest, [priv] may hold a `dapkey1.` passphrase-encrypted envelope
/// instead of plaintext (see `dap_key_envelope.dart`); the delivery layer
/// only ever sees the decrypted form in memory.
final class DapChannelMembership {
  const DapChannelMembership({
    required this.hubUrl,
    required this.channelId,
    required this.scope,
    required this.joinedAt,
    this.pub,
    this.priv,
  });

  /// The hub this channel lives on — per-channel, so an invite for a
  /// DIFFERENT hub never clobbers the default hub config (E3).
  final String hubUrl;

  /// The channel id (no leading `#`).
  final String channelId;

  /// Where this membership is stored / how far it reaches.
  final DapChannelScope scope;

  /// Join time (UTC) — informational, stable across resumes.
  final DateTime joinedAt;

  /// Channel public key (base64), when the channel is private.
  final String? pub;

  /// Channel private key (base64 plaintext in memory, or a `dapkey1.`
  /// envelope at rest).
  final String? priv;

  /// The dedup identity: same hub + same channel = same membership,
  /// regardless of scope.
  String get key => '$hubUrl\n$channelId';

  DapChannelMembership withScope(DapChannelScope newScope) =>
      DapChannelMembership(
        hubUrl: hubUrl,
        channelId: channelId,
        scope: newScope,
        joinedAt: joinedAt,
        pub: pub,
        priv: priv,
      );

  /// Serializes for the session record / project store. Secrets handling
  /// (encryption of [priv]) is the store's job, not the record's.
  Map<String, Object?> toJson() => {
    'hubUrl': hubUrl,
    'channelId': channelId,
    'scope': scope.name,
    'joinedAt': joinedAt.toUtc().toIso8601String(),
    if (pub != null) 'pub': pub,
    if (priv != null) 'priv': priv,
  };

  /// Tolerant reader: unknown scope values fall back to null (caller
  /// skips), malformed records throw [FormatException] so a corrupted
  /// store fails loudly instead of silently dropping memberships.
  static DapChannelMembership fromJson(Map<String, Object?> json) {
    final hubUrl = json['hubUrl'];
    final channelId = json['channelId'];
    final scopeName = json['scope'];
    if (hubUrl is! String || hubUrl.isEmpty) {
      throw const FormatException('membership: missing hubUrl');
    }
    if (channelId is! String || channelId.isEmpty) {
      throw const FormatException('membership: missing channelId');
    }
    final scope = DapChannelScope.values.where((s) => s.name == scopeName);
    if (scope.isEmpty) {
      throw FormatException('membership: unknown scope "$scopeName"');
    }
    final joinedAtRaw = json['joinedAt'];
    final joinedAt = joinedAtRaw is String
        ? DateTime.tryParse(joinedAtRaw)
        : null;
    return DapChannelMembership(
      hubUrl: hubUrl,
      channelId: channelId,
      scope: scope.first,
      joinedAt: joinedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      pub: json['pub'] as String?,
      priv: json['priv'] as String?,
    );
  }
}

/// The union of all scope stores, deduped by `(hubUrl, channelId)`.
///
/// Precedence on conflict: session > project > global — the NARROWEST
/// scope wins the key material, so a session join with fresh invite keys
/// cannot be shadowed by a stale global entry. Delivery dedups by [key]
/// either way; the scope badges list every scope a channel is joined at.
final class DapMembershipUnion {
  DapMembershipUnion(Iterable<DapChannelMembership> memberships) {
    for (final m in memberships) {
      _byKey.putIfAbsent(m.key, () => []).add(m);
    }
  }

  final Map<String, List<DapChannelMembership>> _byKey = {};

  static const _precedence = [
    DapChannelScope.session,
    DapChannelScope.project,
    DapChannelScope.global,
  ];

  /// One effective membership per `(hubUrl, channelId)`, narrowest scope
  /// winning the key material.
  List<DapChannelMembership> effective() {
    final out = <DapChannelMembership>[];
    for (final entry in _byKey.entries) {
      final candidates = entry.value;
      candidates.sort(
        (a, b) => _precedence
            .indexOf(a.scope)
            .compareTo(_precedence.indexOf(b.scope)),
      );
      out.add(candidates.first);
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  /// Every scope a given channel is joined at (for the `/network` badges).
  List<DapChannelScope> scopesOf(String hubUrl, String channelId) {
    final key = '$hubUrl\n$channelId';
    final candidates = _byKey[key] ?? const [];
    final scopes = candidates.map((m) => m.scope).toSet();
    return [
      for (final s in _precedence)
        if (scopes.contains(s)) s,
    ];
  }

  /// The union that remains after leaving `(hubUrl, channelId)` at
  /// [scope] — other scopes keep the channel alive (E1).
  DapMembershipUnion leaving(
    String hubUrl,
    String channelId,
    DapChannelScope scope,
  ) {
    final key = '$hubUrl\n$channelId';
    return DapMembershipUnion([
      for (final entry in _byKey.entries)
        for (final m in entry.value)
          if (!(entry.key == key && m.scope == scope)) m,
    ]);
  }
}
