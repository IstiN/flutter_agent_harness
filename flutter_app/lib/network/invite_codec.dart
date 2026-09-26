// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Invite link codecs for fa_network.
///
/// fa_network has no invite format of its own; these are client-side
/// conventions of the Fa app:
///
/// a) Agent invite (AC-B17 minimal pair, private channels only):
///    `wss://<hubhost>/<path>?channel=<name>#pub=<b64>&priv=<b64>`
///    The channel X25519 keys travel in the URI *fragment*, which per
///    RFC 3986 is client-side only and never sent on the wire.
///
/// b) Network join link for humans:
///    `https://<host>/join?network=<id>#pw=<urlsafe password>`
///    The fragment (password) is optional — when absent, the user enters
///    the password manually in the confirmation dialog.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A parsed agent invite.
typedef AgentInvite = ({
  /// The hub WebSocket URI with the `channel` query parameter and the
  /// key fragment stripped — safe to connect to.
  Uri hubUri,

  /// The private channel name.
  String channel,

  /// Base64 channel X25519 public key (32 bytes decoded).
  String pub,

  /// Base64 channel X25519 private key (32 bytes decoded).
  String priv,
});

/// A parsed network join link.
typedef NetworkJoinLink = ({
  /// The server origin (scheme + host + port) for the confirmation dialog.
  Uri host,

  /// The network id to join.
  String networkId,

  /// The network password, or null when the link carried no fragment and
  /// the user must enter it manually.
  String? password,
});

/// Base class for invite link format errors.
class InviteFormatException extends FormatException {
  /// Creates an exception with a human-readable [message].
  InviteFormatException(super.message);
}

/// Thrown when an agent invite fails strict validation.
class AgentInviteFormatException extends InviteFormatException {
  /// Creates an exception with a human-readable [message].
  AgentInviteFormatException(super.message);
}

/// Thrown when a network join link fails validation.
class NetworkJoinLinkFormatException extends InviteFormatException {
  /// Creates an exception with a human-readable [message].
  NetworkJoinLinkFormatException(super.message);
}

/// Parses an agent invite of the form
/// `wss://<hubhost>/<path>?channel=<name>#pub=<b64>&priv=<b64>`.
///
/// STRICT: the scheme must be `wss`, `channel`/`pub`/`priv` must be
/// present, and `pub`/`priv` must be base64 decoding to 32 bytes each.
/// Anything else throws [AgentInviteFormatException] with a human-readable
/// reason.
AgentInvite parseAgentInvite(String raw) {
  final uri = _parse(raw, AgentInviteFormatException.new);
  if (uri.scheme != 'wss') {
    throw AgentInviteFormatException(
      'agent invite scheme must be wss, got '
      "'${uri.scheme.isEmpty ? '(none)' : uri.scheme}'",
    );
  }
  if (uri.host.isEmpty) {
    throw AgentInviteFormatException('agent invite is missing the host');
  }
  final channel = uri.queryParameters['channel'];
  if (channel == null || channel.isEmpty) {
    throw AgentInviteFormatException(
      'agent invite is missing the channel query parameter',
    );
  }
  if (uri.fragment.isEmpty) {
    throw AgentInviteFormatException(
      'agent invite is missing the #pub=...&priv=... fragment',
    );
  }
  final fragmentParams = _splitFragment(uri.fragment, 'agent invite');
  final pub = _decodeX25519Key(fragmentParams['pub'], 'pub');
  final priv = _decodeX25519Key(fragmentParams['priv'], 'priv');
  // The connect URI must not carry keys or the channel param. Rebuild:
  // Uri.replace(query: '', fragment: '') would leave a dangling '?#'.
  final restQuery = Map.of(uri.queryParameters)..remove('channel');
  final hubUri = Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: restQuery.isEmpty ? null : restQuery,
  );
  return (
    hubUri: hubUri,
    channel: channel,
    pub: base64UrlEncode(pub),
    priv: base64UrlEncode(priv),
  );
}

/// Builds an agent invite (inverse of [parseAgentInvite]). Validates the
/// same invariants and throws [AgentInviteFormatException] on violation.
String buildAgentInvite({
  required Uri hubUri,
  required String channel,
  required String pub,
  required String priv,
}) {
  if (hubUri.scheme != 'wss') {
    throw AgentInviteFormatException(
      "agent invite scheme must be wss, got '${hubUri.scheme}'",
    );
  }
  if (hubUri.host.isEmpty) {
    throw AgentInviteFormatException('agent invite is missing the host');
  }
  if (channel.isEmpty) {
    throw AgentInviteFormatException('agent invite channel is empty');
  }
  // Validate, then re-encode URL-safe (fragments must not carry '+'/'/').
  final pubB64 = base64UrlEncode(_decodeX25519Key(pub, 'pub'));
  final privB64 = base64UrlEncode(_decodeX25519Key(priv, 'priv'));
  final query = Map.of(hubUri.queryParameters);
  query['channel'] = channel;
  return hubUri
      .replace(
        query: Uri(queryParameters: query).query,
        fragment: Uri(queryParameters: {'pub': pubB64, 'priv': privB64}).query,
      )
      .toString();
}

/// Builds a PUBLIC-channel agent invite: `wss://<hub>?channel=<id>` with
/// NO key material (public channels have no chankey — payloads are raw
/// by the showcase contract). Strict on the same invariants.
String buildPublicAgentInvite({required Uri hubUri, required String channel}) {
  if (hubUri.scheme != 'wss') {
    throw AgentInviteFormatException(
      "agent invite scheme must be wss, got '\${hubUri.scheme}'",
    );
  }
  if (hubUri.host.isEmpty) {
    throw AgentInviteFormatException('agent invite is missing the host');
  }
  if (channel.isEmpty) {
    throw AgentInviteFormatException('agent invite channel is empty');
  }
  final query = Map.of(hubUri.queryParameters);
  query['channel'] = channel;
  return hubUri.replace(query: Uri(queryParameters: query).query).toString();
}

/// Parses a network join link of the form
/// `https://<host>/join?network=<id>#pw=<urlsafe password>`.
///
/// Tolerant of a missing fragment — [NetworkJoinLink.password] is then
/// null and the user enters the password manually. Everything else is
/// strict: scheme must be `https`, host must be present, `network` must
/// be a non-empty query parameter.
NetworkJoinLink parseNetworkJoinLink(String raw) {
  final uri = _parse(raw, NetworkJoinLinkFormatException.new);
  if (uri.scheme != 'https') {
    throw NetworkJoinLinkFormatException(
      'join link scheme must be https, got '
      "'${uri.scheme.isEmpty ? '(none)' : uri.scheme}'",
    );
  }
  if (uri.host.isEmpty) {
    throw NetworkJoinLinkFormatException('join link is missing the host');
  }
  final networkId = uri.queryParameters['network'];
  if (networkId == null || networkId.isEmpty) {
    throw NetworkJoinLinkFormatException(
      'join link is missing the network query parameter',
    );
  }
  String? password;
  if (uri.fragment.isNotEmpty) {
    password = _splitFragment(uri.fragment, 'join link')['pw'];
  }
  return (
    host: Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ),
    networkId: networkId,
    password: (password == null || password.isEmpty) ? null : password,
  );
}

/// Builds a network join link (inverse of [parseNetworkJoinLink]).
String buildNetworkJoinLink({
  required Uri host,
  required String networkId,
  String? password,
}) {
  if (host.scheme != 'https') {
    throw NetworkJoinLinkFormatException(
      "join link scheme must be https, got '${host.scheme}'",
    );
  }
  if (host.host.isEmpty) {
    throw NetworkJoinLinkFormatException('join link is missing the host');
  }
  if (networkId.isEmpty) {
    throw NetworkJoinLinkFormatException('join link network id is empty');
  }
  return Uri(
    scheme: host.scheme,
    host: host.host,
    port: host.hasPort ? host.port : null,
    path: '/join',
    queryParameters: {'network': networkId},
    fragment: (password == null || password.isEmpty)
        ? null
        : Uri(queryParameters: {'pw': password}).query,
  ).toString();
}

Uri _parse(String raw, InviteFormatException Function(String) error) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw error('invite is empty');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    throw error('invite is not a valid URI');
  }
  return uri;
}

Map<String, String> _splitFragment(String fragment, String what) {
  try {
    return Uri.splitQueryString(fragment);
  } on Object {
    throw FormatException('$what fragment is not valid key=value pairs');
  }
}

Uint8List _decodeX25519Key(String? value, String field) {
  if (value == null || value.isEmpty) {
    throw AgentInviteFormatException(
      'agent invite is missing the $field key in the fragment',
    );
  }
  Uint8List? bytes;
  try {
    bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  } on Object {
    try {
      bytes = Uint8List.fromList(base64.decode(value));
    } on Object {
      throw AgentInviteFormatException('$field is not valid base64');
    }
  }
  if (bytes.length != 32) {
    throw AgentInviteFormatException(
      '$field must decode to 32 bytes (X25519 key), got ${bytes.length}',
    );
  }
  return bytes;
}
