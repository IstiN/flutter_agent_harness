import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Immutable, host-supplied product identity for a branded Fa workspace.
///
/// The harness ships no product backends or credentials. [stock] is the only
/// configuration that preserves legacy browser storage keys and it can never
/// enable cloud synchronization. Any explicitly supplied profile is branded,
/// including one whose id happens to be `fa`.
final class FaProductConfig {
  const FaProductConfig({
    required this.productId,
    required this.displayName,
    this.description = '',
    this.brandAssets = const {},
    this.themePackId,
    this.authEndpoint,
    this.apiEndpoint,
    this.driveEndpoint,
    this.sessionEndpoint,
    this.oauthCallback,
    this.legalLinks = const {},
    this.featureFlags = const {},
  }) : _stock = false;

  const FaProductConfig._stock()
    : productId = 'fa',
      displayName = 'Fa',
      description = 'Fa — Flutter Agent Harness: coding agent in your browser.',
      brandAssets = const {},
      themePackId = null,
      authEndpoint = null,
      apiEndpoint = null,
      driveEndpoint = null,
      sessionEndpoint = null,
      oauthCallback = null,
      legalLinks = const {},
      featureFlags = const {},
      _stock = true;

  /// Default Fa identity. No profile file is required to retain this behavior.
  static const stock = FaProductConfig._stock();

  final String productId;
  final String displayName;
  final String description;

  /// Logical asset slot (`icon192`, `icon512`, `favicon`, `splash`, …) to a
  /// normalized relative path inside the host's external asset directory.
  final Map<String, String> brandAssets;
  final String? themePackId;
  final Uri? authEndpoint;
  final Uri? apiEndpoint;
  final Uri? driveEndpoint;
  final Uri? sessionEndpoint;
  final Uri? oauthCallback;
  final Map<String, Uri> legalLinks;
  final Set<String> featureFlags;
  final bool _stock;

  bool get isStock => _stock;

  /// Cloud work requires BOTH an explicit flag and a real endpoint. Merely
  /// parsing a product profile never registers a provider or starts sync.
  bool get cloudSyncEnabled =>
      !_stock &&
      featureFlags.contains('cloudSync') &&
      (driveEndpoint != null || sessionEndpoint != null);

  /// Product/schema storage namespace. `null` is the compatibility sentinel:
  /// browser stores keep their pre-product legacy keys for stock Fa.
  String? storageNamespace(int schema) {
    if (schema < 1) throw ArgumentError.value(schema, 'schema');
    return _stock ? null : 'fa-product:$productId:schema:$schema';
  }

  /// Account partition below [storageNamespace], keyed by the verified
  /// immutable tenant+subject. Device id and auth generation fence work but do
  /// not silently move an account's existing local cache on re-authentication.
  String accountNamespace(CloudIdentity identity, int schema) {
    identity.validate();
    final product = storageNamespace(schema);
    if (product == null) {
      throw StateError('stock Fa has no account cloud namespace');
    }
    return '$product:account:${identity.accountKey}';
  }

  /// Exact callback matching plus non-empty state validation. Host auth
  /// coordinators call this instead of growing product-specific forks.
  bool acceptsOAuthCallback(
    Uri callback, {
    required String expectedState,
    required String? receivedState,
  }) {
    final expected = oauthCallback;
    return expected != null &&
        callback == expected &&
        expectedState.isNotEmpty &&
        receivedState == expectedState;
  }

  /// Parses and validates an external JSON profile. Unknown fields are
  /// tolerated for forward compatibility, but credential-shaped fields are
  /// rejected recursively so secrets cannot hide in extension metadata.
  factory FaProductConfig.fromJson(Map<String, Object?> json) {
    _rejectSecretFields(json);
    final productId = _id(json['productId'], 'productId');
    final displayName = _text(json['displayName'], 'displayName');
    final description = json['description'] == null
        ? ''
        : _text(json['description'], 'description', allowEmpty: true);
    final themePackId = json['themePackId'] == null
        ? null
        : _id(json['themePackId'], 'themePackId');
    final assets = <String, String>{};
    final rawAssets = json['brandAssets'];
    if (rawAssets != null) {
      if (rawAssets is! Map) throw const FormatException('brandAssets map');
      for (final entry in rawAssets.entries) {
        final slot = _id(entry.key, 'brandAssets slot');
        assets[slot] = _assetPath(entry.value);
      }
    }
    Uri? endpoint(String name) {
      final value = json[name];
      if (value == null) return null;
      if (value is! String) throw FormatException('$name must be a URI');
      final uri = Uri.tryParse(value);
      if (uri == null || !_secureEndpoint(uri)) {
        throw FormatException('$name must be an HTTPS endpoint: $value');
      }
      return uri;
    }

    final legal = <String, Uri>{};
    final rawLegal = json['legalLinks'];
    if (rawLegal != null) {
      if (rawLegal is! Map) throw const FormatException('legalLinks map');
      for (final entry in rawLegal.entries) {
        final key = _id(entry.key, 'legalLinks key');
        final uri = Uri.tryParse(entry.value.toString());
        if (uri == null || !_secureEndpoint(uri)) {
          throw FormatException('legal link $key must use HTTPS');
        }
        legal[key] = uri;
      }
    }
    final flags = <String>{};
    final rawFlags = json['featureFlags'];
    if (rawFlags != null) {
      if (rawFlags is! List) throw const FormatException('featureFlags list');
      for (final flag in rawFlags) {
        flags.add(_featureFlag(flag));
      }
    }
    final config = FaProductConfig(
      productId: productId,
      displayName: displayName,
      description: description,
      brandAssets: Map.unmodifiable(assets),
      themePackId: themePackId,
      authEndpoint: endpoint('authEndpoint'),
      apiEndpoint: endpoint('apiEndpoint'),
      driveEndpoint: endpoint('driveEndpoint'),
      sessionEndpoint: endpoint('sessionEndpoint'),
      oauthCallback: endpoint('oauthCallback'),
      legalLinks: Map.unmodifiable(legal),
      featureFlags: Set.unmodifiable(flags),
    );
    if (config.oauthCallback != null && config.authEndpoint == null) {
      throw const FormatException('oauthCallback requires authEndpoint');
    }
    return config;
  }

  static bool _secureEndpoint(Uri uri) {
    if (!uri.hasScheme || uri.host.isEmpty || uri.hasFragment) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '[::1]' ||
            uri.host == '::1');
  }

  static String _id(Object? value, String name) {
    if (value is! String ||
        !RegExp(r'^[a-z][a-z0-9._-]{0,63}$').hasMatch(value)) {
      throw FormatException('$name must be a lowercase stable id');
    }
    return value;
  }

  static String _featureFlag(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9._-]{0,63}$').hasMatch(value)) {
      throw const FormatException('feature flag must be a stable id');
    }
    return value;
  }

  static String _text(Object? value, String name, {bool allowEmpty = false}) {
    if (value is! String ||
        (!allowEmpty && value.trim().isEmpty) ||
        value.contains(RegExp(r'[<>\x00-\x1f\x7f]'))) {
      throw FormatException('$name contains unsafe text');
    }
    return value;
  }

  static String _assetPath(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('asset path must be a string');
    }
    if (value.startsWith('/') ||
        value.contains('\\') ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('asset path must be relative POSIX');
    }
    final parts = value.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('invalid asset path: $value');
    }
    return parts.join('/');
  }

  static void _rejectSecretFields(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase().replaceAll(
          RegExp('[^a-z]'),
          '',
        );
        if (key == 'apikey' ||
            key == 'token' ||
            key == 'accesstoken' ||
            key == 'refreshtoken' ||
            key == 'password' ||
            key == 'secret' ||
            key == 'clientsecret' ||
            key == 'credential' ||
            key == 'credentials') {
          throw FormatException('credential field forbidden: ${entry.key}');
        }
        _rejectSecretFields(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _rejectSecretFields(item);
      }
    }
  }
}

/// Verified account/device identity supplied by the host auth layer.
final class CloudIdentity {
  const CloudIdentity({
    required this.tenantId,
    required this.subject,
    required this.deviceId,
    required this.authGeneration,
  });

  final String tenantId;

  /// Immutable issuer subject, never an email address or display name.
  final String subject;
  final String deviceId;
  final int authGeneration;

  void validate() {
    for (final (name, value) in [
      ('tenantId', tenantId),
      ('subject', subject),
      ('deviceId', deviceId),
    ]) {
      if (value.isEmpty || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw FormatException('$name is invalid');
      }
    }
    if (subject.contains('@')) {
      throw const FormatException('subject must be immutable, never email');
    }
    if (authGeneration < 1) {
      throw ArgumentError.value(authGeneration, 'authGeneration');
    }
  }

  /// Stable local account key. Raw tenant/subject values are not exposed as
  /// IndexedDB, service-worker, or cache names.
  String get accountKey {
    validate();
    return sha256
        .convert(utf8.encode('tenant\u0000$tenantId\nsubject\u0000$subject'))
        .toString();
  }

  /// True only for the same live writer fence. Sign-out/account switch must
  /// advance [authGeneration], making every older in-flight operation stale.
  bool canWriteFor(CloudIdentity active) {
    validate();
    active.validate();
    return tenantId == active.tenantId &&
        subject == active.subject &&
        deviceId == active.deviceId &&
        authGeneration == active.authGeneration;
  }

  CloudIdentity nextGeneration() => CloudIdentity(
    tenantId: tenantId,
    subject: subject,
    deviceId: deviceId,
    authGeneration: authGeneration + 1,
  );
}
