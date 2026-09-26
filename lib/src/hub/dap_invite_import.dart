// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Parser for the Fa app's add-agent invite string (issue #955, the AC-B17
/// minimal pair):
///
///     wss://<hub-host>/<path>?channel=<name>#pub=<b64>&priv=<b64>
///
/// The channel X25519 keypair rides the URL FRAGMENT — fragments never
/// leave the client in any HTTP/WS request, so the key material cannot
/// leak onto the wire by construction (I2). The hub URL (scheme, host,
/// path, query minus the channel param is irrelevant) is what the
/// importing agent dials.
library;

import 'dart:convert';

/// A parsed add-agent invite.
final class DapInviteImport {
  const DapInviteImport({
    required this.hubUrl,
    required this.channel,
    required this.pub,
    required this.priv,
  });

  /// The hub websocket URL the agent dials (fragment stripped — the
  /// keypair never travels).
  final String hubUrl;

  /// The channel to join.
  final String channel;

  /// Channel X25519 keypair, base64 (32 raw bytes each).
  final String pub;
  final String priv;
}

/// Strict parser — hostile or malformed strings are rejected with a
/// human-readable reason, never partially accepted.
DapInviteImport parseDapInviteImport(String raw) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on Object {
    throw const FormatException('not a URI');
  }
  if (uri.scheme != 'wss' && uri.scheme != 'ws') {
    throw FormatException(
      'scheme must be wss:// (or ws:// for a local hub), got '
      '${uri.scheme.isEmpty ? 'none' : '${uri.scheme}://'}',
    );
  }
  if (uri.host.isEmpty) {
    throw const FormatException('missing hub host');
  }
  final channel = uri.queryParameters['channel'];
  if (channel == null || channel.isEmpty) {
    throw const FormatException('missing ?channel= query parameter');
  }
  if (uri.fragment.isEmpty) {
    throw const FormatException(
      'missing #pub=…&priv=… fragment — the invite carries the channel '
      'key in the fragment',
    );
  }
  final params = Uri.splitQueryString(uri.fragment);
  final pub = _keyParam(params, 'pub');
  final priv = _keyParam(params, 'priv');
  return DapInviteImport(
    hubUrl: uri.removeFragment().toString(),
    channel: channel,
    pub: pub,
    priv: priv,
  );
}

String _keyParam(Map<String, String> params, String name) {
  final value = params[name];
  if (value == null || value.isEmpty) {
    throw FormatException('missing fragment parameter $name=');
  }
  final List<int> bytes;
  try {
    bytes = base64Decode(value);
  } on Object {
    throw FormatException('fragment parameter $name= is not base64');
  }
  if (bytes.length != 32) {
    throw FormatException(
      'fragment parameter $name= must decode to 32 bytes '
      '(got ${bytes.length})',
    );
  }
  return value;
}
