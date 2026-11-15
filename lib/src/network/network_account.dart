// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Persistable ai-native account and enrolled-device credential models.
/// Secret fields are excluded from [Object.toString]; storage and command
/// implementations must never log their JSON documents.
library;

import 'dart:convert';

/// The signed-in ai-native account. [expiresAt] and [refreshToken] are
/// nullable because the headless `--jwt` flow receives only an access token.
final class NetworkAccount {
  /// Builds an account credential set.
  const NetworkAccount({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.refreshExpiresAt,
    this.subject,
    this.email,
    this.displayName,
  });

  /// The ai-native account JWT used by management endpoints.
  final String accessToken;

  /// Refresh credential for `POST /api/auth/refresh`, when issued.
  final String? refreshToken;

  /// Absolute UTC access-token expiry, when declared by OAuth or JWT `exp`.
  final DateTime? expiresAt;

  /// Absolute UTC refresh-token expiry, when declared.
  final DateTime? refreshExpiresAt;

  /// JWT `sub`, when available.
  final String? subject;

  /// Account email, when available.
  final String? email;

  /// Account display name, when available.
  final String? displayName;

  /// Creates the headless pasted-token form. The token is intentionally not
  /// required to be a JWT: opaque bearer tokens are stored verbatim too.
  factory NetworkAccount.fromJwt(String token) {
    final claims = jwtClaims(token);
    return NetworkAccount(
      accessToken: token,
      expiresAt: _dateClaim(claims?['exp']),
      subject: _stringClaim(claims?['sub']),
      email: _stringClaim(claims?['email']),
      displayName: _stringClaim(claims?['name']),
    );
  }

  /// Parses a stored JSON document; throws [FormatException] on corrupt or
  /// secret-free content rather than silently replacing it.
  factory NetworkAccount.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('account must be an object');
    final token = json['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('account accessToken is missing');
    }
    return NetworkAccount(
      accessToken: token,
      refreshToken: _nonEmpty(json['refreshToken']),
      expiresAt: _parseDate(json['expiresAt']),
      refreshExpiresAt: _parseDate(json['refreshExpiresAt']),
      subject: _nonEmpty(json['subject']),
      email: _nonEmpty(json['email']),
      displayName: _nonEmpty(json['displayName']),
    );
  }

  /// Storage representation. This contains secrets: never print it.
  Map<String, Object?> toJson() => {
    'version': 1,
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (refreshExpiresAt != null)
      'refreshExpiresAt': refreshExpiresAt!.toUtc().toIso8601String(),
    if (subject != null) 'subject': subject,
    if (email != null) 'email': email,
    if (displayName != null) 'displayName': displayName,
  };

  /// Whether the access token is expired at [now]. Unknown expiry is usable.
  bool isExpired(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now.toUtc());

  /// Best non-secret label for status output.
  String get label => displayName ?? email ?? subject ?? 'signed in';

  @override
  String toString() => 'NetworkAccount($label, accessToken:<redacted>)';
}

/// Enrolled device credentials persisted independently of the account so
/// logging out can revoke the local pairing by deleting both documents.
final class NetworkDeviceCredentials {
  /// Builds an enrolled-device record.
  const NetworkDeviceCredentials({
    required this.deviceId,
    required this.deviceToken,
    this.personalNetworkId,
    this.name,
    this.friendlyName,
    this.platform,
    this.dmPrivateKeys = const {},
  });

  /// Stable server-issued device id.
  final String deviceId;

  /// Opaque device bearer used for ticket minting. Never log it.
  final String deviceToken;

  /// Personal network used for presence exposure.
  final String? personalNetworkId;

  /// Host display name supplied at enrollment.
  final String? name;

  /// Owner-set friendly name returned by the rename endpoint.
  final String? friendlyName;

  /// Host platform supplied at enrollment.
  final String? platform;

  /// Base64 X25519 DM private seeds keyed by full `<agent>@<device>` address.
  /// Secret key material: never log this map.
  final Map<String, String> dmPrivateKeys;

  /// Parses a stored JSON document.
  factory NetworkDeviceCredentials.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('device must be an object');
    final id = json['deviceId'];
    final token = json['deviceToken'];
    if (id is! String || id.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('deviceId/deviceToken are missing');
    }
    return NetworkDeviceCredentials(
      deviceId: id,
      deviceToken: token,
      personalNetworkId: _nonEmpty(json['personalNetworkId']),
      name: _nonEmpty(json['name']),
      friendlyName: _nonEmpty(json['friendlyName']),
      platform: _nonEmpty(json['platform']),
      dmPrivateKeys: _dmPrivateKeys(json['dmPrivateKeys']),
    );
  }

  /// Storage representation. This contains a bearer: never print it.
  Map<String, Object?> toJson() => {
    'version': 1,
    'deviceId': deviceId,
    'deviceToken': deviceToken,
    if (personalNetworkId != null) 'personalNetworkId': personalNetworkId,
    if (name != null) 'name': name,
    if (friendlyName != null) 'friendlyName': friendlyName,
    if (platform != null) 'platform': platform,
    if (dmPrivateKeys.isNotEmpty) 'dmPrivateKeys': dmPrivateKeys,
  };

  /// Returns the same enrollment record with an updated DM private-key map.
  NetworkDeviceCredentials withDmPrivateKeys(Map<String, String> keys) =>
      NetworkDeviceCredentials(
        deviceId: deviceId,
        deviceToken: deviceToken,
        personalNetworkId: personalNetworkId,
        name: name,
        friendlyName: friendlyName,
        platform: platform,
        dmPrivateKeys: Map.unmodifiable(keys),
      );

  @override
  String toString() =>
      'NetworkDeviceCredentials($deviceId, deviceToken:<redacted>)';
}

/// Decodes the claims of a JWT without authenticating it. This is used only
/// for local expiry/display metadata; the server remains the auth authority.
Map<String, Object?>? jwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final decoded = jsonDecode(payload);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on Object {
    return null;
  }
}

DateTime? _dateClaim(Object? value) {
  if (value is! num || value <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (value * 1000).round(),
    isUtc: true,
  );
}

DateTime? _parseDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String? _stringClaim(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, String> _dmPrivateKeys(Object? value) {
  if (value is! Map) return const {};
  return Map.unmodifiable({
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  });
}

String? _nonEmpty(Object? value) => _stringClaim(value);
