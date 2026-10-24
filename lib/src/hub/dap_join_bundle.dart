// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Parser for the Fa app's Add an agent → **DAP** enrollment bundle
/// (issue #1825 follow-up): the invite link ALONE is not enough on a hub
/// that enrolls name-bound agent credentials — the app's own CLI command
/// carries `DAP_HUB_URL`, `DAP_CLIENT_SECRET` and `DAP_AGENT_NAME` next
/// to the `fa dap import` invite, and a secret enrolled on one hub is
/// rejected by another (live diagnosis: HTTP 401 with the machine's
/// default credential, `hello name does not match the enrolled secret`
/// with the wrong agent name).
///
/// Accepted pastes (the invite is required, everything else optional):
/// - the bare invite url / `#pub=…&priv=…` form / bare channel id;
/// - `fa dap import` with the quoted or bare url;
/// - the one-line app command `fa dap import` + `&& DAP_HUB_URL=…
///   DAP_CLIENT_SECRET='…' DAP_AGENT_NAME=… fa`;
/// - the multi-line DAP tab block (one assignment per line + import).
///
/// The secret is NEVER included in error messages or logs.
library;

import 'dap_invite_import.dart';

/// A parsed join request: the channel invite plus the optional hub
/// credential the app enrolled for this agent.
final class DapJoinBundle {
  const DapJoinBundle({
    required this.invite,
    required this.hubUrl,
    this.clientSecret,
    this.agentName,
  });

  /// The channel invite (keys included for private channels).
  final DapInviteImport invite;

  /// The hub to dial — an explicit `DAP_HUB_URL` wins over the invite's
  /// own url (they carry the same value in the app's command).
  final String hubUrl;

  /// The hub-issued, name-bound client secret (null for keyless hubs).
  final String? clientSecret;

  /// The enrolled agent display name ([clientSecret] is bound to it).
  final String? agentName;
}

/// An env-style assignment, single/double-quoted or bare, anywhere in
/// the paste (multi-line block or one-line shell command).
String? _assignment(String text, String name) {
  final match = RegExp(
    '(?:^|[\\s&;])$name=((?:\'[^\']*\')|(?:"[^"]*")|(?:[^\\s&;]+))',
    multiLine: true,
  ).firstMatch(text);
  if (match == null) return null;
  var value = match.group(1)!.trim();
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    value = value.substring(1, value.length - 1);
  }
  return value.isEmpty ? null : value;
}

/// The invite token after `fa dap import`, quoted or bare. Only the
/// FIRST import is considered; the rest of the command line (`&& …`,
/// env assignments, the trailing `fa`) is not executed, just parsed.
String? _importToken(String text) {
  final match = RegExp(
    'fa\\s+dap\\s+import\\s+(\'[^\']*\'|"[^"]*"|\\S+)',
  ).firstMatch(text);
  if (match == null) return null;
  final token = match.group(1)!;
  return token.length >= 2 &&
          ((token.startsWith("'") && token.endsWith("'")) ||
              (token.startsWith('"') && token.endsWith('"')))
      ? token.substring(1, token.length - 1)
      : token;
}

/// Parses any accepted paste into a [DapJoinBundle]. Throws
/// [FormatException] with an actionable, secret-free reason otherwise.
DapJoinBundle parseDapJoinBundle(String raw, {String? defaultHubUrl}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('empty invite');
  }
  final secret = _assignment(trimmed, 'DAP_CLIENT_SECRET');
  final agentName = _assignment(trimmed, 'DAP_AGENT_NAME');
  final explicitHub = _assignment(trimmed, 'DAP_HUB_URL');

  final token = _importToken(trimmed);
  final inviteText = token ?? trimmed;
  final DapInviteImport invite;
  try {
    invite = parseDapInviteFlexible(
      inviteText,
      defaultHubUrl: explicitHub ?? defaultHubUrl,
    );
  } on FormatException {
    // A full DAP block whose import line could not be found (e.g. the
    // user copied only the env assignments): say what is missing.
    if (token == null && (secret != null || explicitHub != null)) {
      throw const FormatException(
        'no invite found — copy the WHOLE DAP block including the '
        'fa dap import line',
      );
    }
    rethrow;
  }
  return DapJoinBundle(
    invite: invite,
    hubUrl: explicitHub ?? invite.hubUrl,
    clientSecret: secret,
    agentName: agentName,
  );
}
