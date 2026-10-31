// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Headless / CI-CD DAP channel provisioning (issue #1825 AC10/AC14/AC15):
/// the `DAP_CHANNELS_JSON` env secret joins channels AT BOOT with zero
/// prompts and zero `$HOME` dependency.
///
/// Shape: `[{"channel":"<id>","pub":"…","priv":"…"}, …]`.
/// - keyless entries are PUBLIC channels;
/// - `priv` may be PLAINTEXT base64 straight from the CI secret store
///   (first-class, no passphrase needed) or a `dapkey1.` envelope
///   (decrypted downstream with `DAP_KEY_PASSPHRASE`);
/// - mixed encrypted + plaintext sets join together;
/// - an optional per-entry `hubUrl` overrides the default hub (E3).
///
/// Failure policy: a malformed ENTRY produces a loud warning and is
/// skipped — DAP is never a hard dependency of the agent's primary job.
library;

import 'dart:convert';

import 'dap_membership.dart';

/// The outcome of parsing `DAP_CHANNELS_JSON`: the valid memberships
/// plus one human-readable warning per skipped entry.
final class DapEnvChannelsResult {
  const DapEnvChannelsResult(this.memberships, this.warnings);

  /// Valid entries, in env order, marked [DapChannelScope.global] — the
  /// env path behaves exactly like a global membership with no `$HOME`.
  final List<DapChannelMembership> memberships;

  /// Loud one-line warnings for skipped entries (empty when all valid).
  final List<String> warnings;

  /// Whether the env carried no usable channels.
  bool get isEmpty => memberships.isEmpty;
}

/// Parses the raw `DAP_CHANNELS_JSON` value. [defaultHubUrl] comes from
/// `DAP_HUB_URL` / the resolved hub config; entries without any hub are
/// skipped with a warning (never a silent guess).
DapEnvChannelsResult parseDapEnvChannels(
  String? raw, {
  String? defaultHubUrl,
  DateTime? joinedAt,
}) {
  final now = joinedAt ?? DateTime.now().toUtc();
  if (raw == null || raw.trim().isEmpty) {
    return const DapEnvChannelsResult([], []);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on Object {
    return const DapEnvChannelsResult([], [
      'DAP_CHANNELS_JSON: not valid JSON — no env channels joined',
    ]);
  }
  if (decoded is! List) {
    return const DapEnvChannelsResult([], [
      'DAP_CHANNELS_JSON: expected a JSON list — no env channels joined',
    ]);
  }
  final memberships = <DapChannelMembership>[];
  final warnings = <String>[];
  for (var i = 0; i < decoded.length; i++) {
    final result = _parseDapEnvEntry(
      decoded[i],
      index: i,
      defaultHubUrl: defaultHubUrl,
      joinedAt: now,
    );
    if (result.warning != null) warnings.add(result.warning!);
    if (result.membership != null) memberships.add(result.membership!);
  }
  return DapEnvChannelsResult(memberships, warnings);
}

({DapChannelMembership? membership, String? warning}) _parseDapEnvEntry(
  Object? entry, {
  required int index,
  required String? defaultHubUrl,
  required DateTime joinedAt,
}) {
  if (entry is! Map) {
    return (
      membership: null,
      warning: 'DAP_CHANNELS_JSON[$index]: not an object — skipped',
    );
  }
  final channel = entry['channel'];
  final hubUrl = entry['hubUrl'] ?? defaultHubUrl;
  if (channel is! String || channel.isEmpty) {
    return (
      membership: null,
      warning: 'DAP_CHANNELS_JSON[$index]: missing "channel" — skipped',
    );
  }
  if (hubUrl is! String || hubUrl.isEmpty) {
    return (
      membership: null,
      warning:
          'DAP_CHANNELS_JSON[$index]: no hubUrl and no DAP_HUB_URL — '
          'skipped (#$channel)',
    );
  }
  final pub = entry['pub'];
  final priv = entry['priv'];
  if (pub != null && pub is! String) {
    return (
      membership: null,
      warning:
          'DAP_CHANNELS_JSON[$index]: "pub" is not a string — '
          'skipped (#$channel)',
    );
  }
  if (priv != null && priv is! String) {
    return (
      membership: null,
      warning:
          'DAP_CHANNELS_JSON[$index]: "priv" is not a string — '
          'skipped (#$channel)',
    );
  }
  return (
    membership: DapChannelMembership(
      hubUrl: hubUrl,
      channelId: channel,
      scope: DapChannelScope.global,
      joinedAt: joinedAt,
      pub: pub as String?,
      priv: priv as String?,
    ),
    warning: null,
  );
}
