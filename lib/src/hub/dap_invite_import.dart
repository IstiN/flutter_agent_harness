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
    this.pub,
    this.priv,
  });

  /// The hub websocket URL the agent dials (fragment stripped — the
  /// keypair never travels).
  final String hubUrl;

  /// The channel to join.
  final String channel;

  /// Channel X25519 keypair, base64/base64url (32 raw bytes each) — null
  /// for a PUBLIC channel invite (keyless by the showcase contract).
  final String? pub;
  final String? priv;
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
  // The fragment carries the keypair for PRIVATE channels; public
  // channels (the showcase contract) have no chankey and no fragment.
  String? pub;
  String? priv;
  if (uri.fragment.isNotEmpty) {
    final params = Uri.splitQueryString(uri.fragment);
    pub = _keyParam(params, 'pub');
    priv = _keyParam(params, 'priv');
  }
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
    // The app emits base64url (URL-safe fragment); plain base64 accepted.
    bytes = base64Url.decode(base64Url.normalize(value));
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

/// The `/network` join wizard input (issue #1825 AC1): one parser for every
/// reasonable paste form, on top of the strict [parseDapInviteImport]:
///
/// 1. the full invite URL (with or without the keypair fragment) — the
///    strict parser handles it unchanged;
/// 2. a bare `<channel-id>` (optionally `#`-prefixed) — joins on
///    [defaultHubUrl] (the configured hub); without one this is a clear
///    error, never a silent guess;
/// 3. the whole copied `fa dap import '…'` command line — the command
///    wrapper (and its shell quotes) is stripped, then form 1 applies.
///
/// Garbage is rejected with a [FormatException]; nothing is partially
/// accepted, so the caller can parse-then-store with no cleanup path.
DapInviteImport parseDapInviteFlexible(String raw, {String? defaultHubUrl}) {
  var text = raw.trim();
  if (text.isEmpty) throw const FormatException('empty invite');

  // Form 3: the copied command line. Only the exact `fa dap import <one
  // arg>` shape unwraps — anything else falls through to the other forms
  // (and their own errors).
  final command = RegExp(r'^fa\s+dap\s+import\s+').firstMatch(text);
  if (command != null) {
    text = text.substring(command.end).trim();
    if (text.length >= 2) {
      final quote = text[0];
      if ((quote == "'" || quote == '"') && text.endsWith(quote)) {
        text = text.substring(1, text.length - 1);
      }
    }
    if (text.isEmpty || text.contains(RegExp(r'\s'))) {
      throw const FormatException(
        'expected exactly one invite after `fa dap import`',
      );
    }
  }

  // Form 2: the bare channel id (no scheme, no whitespace).
  if (!text.contains('://')) {
    if (text.contains(RegExp(r'\s'))) {
      throw const FormatException('not an invite or channel id');
    }
    final channel = text.startsWith('#') ? text.substring(1) : text;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(channel)) {
      throw const FormatException('not an invite or channel id');
    }
    final hub = defaultHubUrl?.trim() ?? '';
    if (hub.isEmpty) {
      throw const FormatException(
        'a bare channel id needs a configured hub url '
        '(set DAP_HUB_URL or paste the full invite)',
      );
    }
    return DapInviteImport(hubUrl: hub, channel: channel);
  }

  // Form 1: the strict URL parser (scheme/host/channel/key validation).
  return parseDapInviteImport(text);
}
