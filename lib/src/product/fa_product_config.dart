import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model_roles/media_model_slots.dart' show mediaModelSlotIds;
import '../model_roles/roles_config.dart' show modelRoleIds;

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
    this.themePack,
    this.authEndpoint,
    this.apiEndpoint,
    this.driveEndpoint,
    this.sessionEndpoint,
    this.oauthCallback,
    this.defaultProviderKey,
    this.localeStorageKey,
    this.legalLinks = const {},
    this.featureFlags = const {},
    this.driveAliases = const {},
    this.storageSchemaVersion = 1,
    this.hostConnection,
    this.providerCatalog,
    this.signInUrl,
    this.channels,
    this.themePicker,
  }) : _stock = false;

  const FaProductConfig._stock()
    : productId = 'fa',
      displayName = 'Fa',
      description = 'Fa — Flutter Agent Harness: coding agent in your browser.',
      brandAssets = const {},
      themePackId = null,
      themePack = null,
      authEndpoint = null,
      apiEndpoint = null,
      driveEndpoint = null,
      sessionEndpoint = null,
      oauthCallback = null,
      defaultProviderKey = null,
      localeStorageKey = null,
      legalLinks = const {},
      featureFlags = const {},
      driveAliases = const {},
      storageSchemaVersion = 1,
      hostConnection = null,
      providerCatalog = null,
      signInUrl = null,
      channels = null,
      themePicker = null,
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
  final Map<String, Object?>? themePack;
  final Uri? authEndpoint;
  final Uri? apiEndpoint;
  final Uri? driveEndpoint;
  final Uri? sessionEndpoint;
  final Uri? oauthCallback;

  /// Optional first-run provider preset selected by a branded product.
  final String? defaultProviderKey;

  /// Optional same-origin localStorage key carrying the host's RU/EN choice.
  final String? localeStorageKey;
  final Map<String, Uri> legalLinks;
  final Set<String> featureFlags;
  final Set<String> driveAliases;
  final int storageSchemaVersion;

  /// The optional host-session bridge (issue #2391): WHERE the host page
  /// publishes a scoped, revocable API key for the signed-in user. Its
  /// presence switches the branded shell onto the host's own models. The
  /// section names a storage location, never a credential value — no
  /// credential can be expressed in a profile.
  final HostConnectionConfig? hostConnection;

  /// The provider-catalog surface policy (gh-2391 addendum 4): absent = the
  /// full stock catalog; `host-only` = a branded build with a bridge NEVER
  /// advertises third-party providers or launches Fa's own OAuth flows —
  /// the only sign-in path is the host's own (see [signInUrl]). Requires
  /// [hostConnection].
  final String? providerCatalog;

  /// True when the profile restricts the provider surface to the host
  /// connection only.
  bool get hostOnlyProviderCatalog => providerCatalog == 'host-only';

  /// The host cabinet's sign-in URL (HTTPS; the host page may encode its
  /// own return parameter). Requires [hostConnection] — the cabinet
  /// publishes the bridge key on sign-in.
  final Uri? signInUrl;

  /// The section-catalog policy (gh-2391 addendum 5): `"host-only"` hides
  /// the Networks surface in a branded build — the rail keeps Local, Apps
  /// (and Devices where an account exists), Settings. Requires
  /// [hostConnection]; absent (stock and every existing profile) all
  /// sections render byte-identically.
  final String? channels;

  /// Whether [channels] pins the host-only section set.
  bool get hostOnlyChannels => channels == 'host-only';

  /// The theme-picker policy (gh-2391 addendum 5): `"profile-locked"`
  /// locks the Theme page to the profile's pack — the stock pack list and
  /// the theme import entry are hidden. Requires [themePackId]; absent
  /// (stock) the picker renders byte-identically.
  final String? themePicker;

  /// Whether [themePicker] locks the Theme page to the profile pack.
  bool get themePickerLocked => themePicker == 'profile-locked';

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
    final aliases = <String>{};
    final rawAliases = json['driveAliases'];
    if (rawAliases != null) {
      if (rawAliases is! List) throw const FormatException('driveAliases list');
      for (final alias in rawAliases) {
        if (alias is! String ||
            !RegExp(r'^/[a-z][a-z0-9_-]{0,63}$').hasMatch(alias) ||
            const {
              '/drive',
              '/.dap',
              '/.env',
              '/logs',
              '/oauth',
            }.contains(alias)) {
          throw const FormatException('invalid drive alias');
        }
        aliases.add(alias);
      }
    }
    final schema = json['storageSchemaVersion'] ?? 1;
    if (schema is! int || schema < 1 || schema > 100) {
      throw const FormatException('storageSchemaVersion must be 1..100');
    }
    final apiEndpointUri = endpoint('apiEndpoint');
    final providerCatalogRaw = json['providerCatalog'];
    final signInUrlRaw = json['signInUrl'];
    if (providerCatalogRaw == null && signInUrlRaw != null) {
      // Reaching here means signInUrl parsed below would lack its
      // prerequisite — validated in full after hostConnection parses.
    }
    final hostConnection = json['hostConnection'] == null
        ? null
        : HostConnectionConfig.fromJson(
            json['hostConnection'],
            apiEndpoint: apiEndpointUri,
            displayName: () => _text(json['displayName'], 'displayName'),
          );
    if (hostConnection != null && flags.contains('cloudSync')) {
      throw const FormatException(
        'hostConnection cannot be combined with cloudSync — a bridge key '
        'grants model access, not a verified CloudIdentity',
      );
    }
    final providerCatalog = _providerCatalog(
      providerCatalogRaw,
      hasHostConnection: hostConnection != null,
    );
    final signInUrl = _signInUrl(
      signInUrlRaw,
      hasHostConnection: hostConnection != null,
    );
    final channels = _catalogPolicy(
      json['channels'],
      name: 'channels',
      allowed: const {'host-only'},
      requires: hostConnection != null,
      requirement: 'hostConnection',
    );
    final themePicker = _catalogPolicy(
      json['themePicker'],
      name: 'themePicker',
      allowed: const {'profile-locked'},
      requires: themePackId != null,
      requirement: 'themePackId',
    );
    final rawThemePack = json['themePack'];
    Map<String, Object?>? themePack;
    if (rawThemePack != null) {
      if (rawThemePack is! Map ||
          rawThemePack['name'] is! String ||
          rawThemePack['version'] is! String ||
          rawThemePack['colors'] is! Map ||
          rawThemePack.containsKey('wallpaper') ||
          rawThemePack.keys.any(
            (key) =>
                const {'code', 'script', 'js', 'url', 'asset'}.contains(key),
          )) {
        throw const FormatException('invalid declarative host themePack');
      }
      _validateThemePackText(rawThemePack);
      themePack = rawThemePack.cast<String, Object?>();
    }
    if (themePack != null && themePackId == null) {
      throw const FormatException('themePack requires themePackId');
    }
    if (themePack != null) {
      final slug = (themePack['name']! as String)
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-|-$'), '');
      if (slug != themePackId) {
        throw const FormatException(
          'themePackId must match the theme name slug',
        );
      }
    }
    final config = FaProductConfig(
      productId: productId,
      displayName: displayName,
      description: description,
      brandAssets: Map.unmodifiable(assets),
      themePackId: themePackId,
      themePack: themePack,
      authEndpoint: endpoint('authEndpoint'),
      apiEndpoint: apiEndpointUri,
      driveEndpoint: endpoint('driveEndpoint'),
      sessionEndpoint: endpoint('sessionEndpoint'),
      oauthCallback: endpoint('oauthCallback'),
      defaultProviderKey: json['defaultProviderKey'] == null
          ? null
          : _id(json['defaultProviderKey'], 'defaultProviderKey'),
      localeStorageKey: json['localeStorageKey'] == null
          ? null
          : _id(json['localeStorageKey'], 'localeStorageKey'),
      legalLinks: Map.unmodifiable(legal),
      featureFlags: Set.unmodifiable(flags),
      driveAliases: Set.unmodifiable(aliases),
      storageSchemaVersion: schema,
      hostConnection: hostConnection,
      providerCatalog: providerCatalog,
      channels: channels,
      themePicker: themePicker,
      signInUrl: signInUrl,
    );
    if (config.oauthCallback != null && config.authEndpoint == null) {
      throw const FormatException('oauthCallback requires authEndpoint');
    }
    return config;
  }

  /// The `providerCatalog` profile field (gh-2391 addendum 4): absent =
  /// the full stock catalog; the only supported value in this card is
  /// `host-only`, and it requires the bridge section.
  /// Shared single-value catalog-policy validator (gh-2391 addendum 5):
  /// `channels` / `themePicker` — an optional string from a fixed value
  /// set with a structural prerequisite.
  static String? _catalogPolicy(
    Object? value, {
    required String name,
    required Set<String> allowed,
    required bool requires,
    required String requirement,
  }) {
    if (value == null) return null;
    if (value is! String || !allowed.contains(value)) {
      throw FormatException(
        '$name must be one of ${allowed.map((e) => '"$e"').join(', ')}',
      );
    }
    if (!requires) {
      throw FormatException('$name "$value" requires $requirement');
    }
    return value;
  }

  static String? _providerCatalog(
    Object? value, {
    required bool hasHostConnection,
  }) {
    if (value == null) return null;
    if (value != 'host-only') {
      throw const FormatException(
        'providerCatalog must be "host-only" (the only catalog policy in '
        'this card)',
      );
    }
    if (!hasHostConnection) {
      throw const FormatException(
        'providerCatalog "host-only" requires hostConnection',
      );
    }
    return value as String;
  }

  /// The `signInUrl` profile field (gh-2391 addendum 4): the host
  /// cabinet's sign-in page (HTTPS; the host encodes its own return
  /// parameter — Fa opens the URL verbatim). Requires the bridge section.
  static Uri? _signInUrl(Object? value, {required bool hasHostConnection}) {
    if (value == null) return null;
    if (!hasHostConnection) {
      throw const FormatException('signInUrl requires hostConnection');
    }
    if (value is! String) {
      throw const FormatException('signInUrl must be a URI');
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw FormatException('signInUrl must be an HTTPS endpoint: $value');
    }
    return uri;
  }

  static bool _secureEndpoint(Uri uri) {
    if (!uri.hasScheme ||
        uri.host.isEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
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

  static void _validateThemePackText(Object? value) {
    if (value is String) {
      _text(value, 'themePack');
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        _validateThemePackText(entry.key);
        _validateThemePackText(entry.value);
      }
      return;
    }
    if (value is Iterable) {
      for (final item in value) {
        _validateThemePackText(item);
      }
    }
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
        if (key.contains('apikey') ||
            key.contains('token') ||
            key.contains('password') ||
            key.contains('secret') ||
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

/// One media slot of a [HostConnectionConfig]: the opaque model id the
/// product's API serves for that modality on the bridged connection.
final class HostMediaSlotConfig {
  const HostMediaSlotConfig._({required this.model});

  /// Opaque model id (the same rule as [HostConnectionConfig.defaultModel]).
  final String model;
}

/// The quota terminal-notice configuration of a [HostConnectionConfig]: the
/// response shape (status + error code) the host uses to say "this user is
/// out of allowance". The optional [url] is the ONLY link Fa ever shows for
/// it — never a URL read out of a response body.
final class HostQuotaConfig {
  const HostQuotaConfig._({
    required this.status,
    required this.errorCode,
    this.url,
  });

  /// HTTP status the host answers with (400..599).
  final int status;

  /// The `error` code in the response body (1..64 chars).
  final String errorCode;

  /// Optional HTTPS link surfaced with the notice (host profile only).
  final Uri? url;
}

/// The host-session bridge section of a product profile (issue #2391):
/// WHERE the signed-in host page publishes a scoped, revocable API key of
/// the product's own API, plus the product's model defaults. Names a
/// storage location — never a credential value; the recursive secret
/// rejection keeps it that way.
final class HostConnectionConfig {
  const HostConnectionConfig._({
    required this.name,
    required this.baseUrl,
    required this.sessionBridge,
    required this.defaultModel,
    required this.modelRoles,
    required this.mediaSlots,
    this.quota,
  });

  /// Parses and validates the `hostConnection` profile section. [apiEndpoint]
  /// is the already-parsed profile endpoint: its presence becomes required
  /// and its origin pins [baseUrl]'s origin. [displayName] is evaluated
  /// lazily — only when `name` is absent.
  factory HostConnectionConfig.fromJson(
    Object? json, {
    required Uri? apiEndpoint,
    required String Function() displayName,
  }) {
    if (json is! Map) throw const FormatException('hostConnection map');
    if (apiEndpoint == null) {
      throw const FormatException(
        'hostConnection requires apiEndpoint — the bridge rides the '
        "product's own API origin",
      );
    }
    final name = json['name'] == null
        ? displayName()
        : _safeText(json['name'], 'hostConnection name');
    final baseUrl = _baseUrl(json['baseUrl'], apiEndpoint);
    final bridge = json['sessionBridge'];
    if (bridge is! Map) {
      throw const FormatException('hostConnection sessionBridge map');
    }
    final storage = bridge['storage'];
    if (storage != 'localStorage') {
      throw const FormatException(
        'sessionBridge.storage must be "localStorage"',
      );
    }
    final key = bridge['key'];
    if (key is! String || !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(key)) {
      throw const FormatException(
        'sessionBridge.key must be 1..64 chars of [A-Za-z0-9._-]',
      );
    }
    final defaultModel = _modelId(json['defaultModel'], 'defaultModel');
    final rawRoles = json['modelRoles'];
    final roles = <String, String>{};
    if (rawRoles != null) {
      if (rawRoles is! Map) {
        throw const FormatException('modelRoles map');
      }
      for (final entry in rawRoles.entries) {
        if (!modelRoleIds.contains(entry.key)) {
          throw FormatException(
            'unknown modelRoles key: ${entry.key} (expected one of '
            '$modelRoleIds)',
          );
        }
        roles[entry.key as String] = _modelId(
          entry.value,
          'modelRoles.${entry.key}',
        );
      }
    }
    final rawSlots = json['mediaSlots'];
    final slots = <String, HostMediaSlotConfig>{};
    if (rawSlots != null) {
      if (rawSlots is! Map) {
        throw const FormatException('mediaSlots map');
      }
      for (final entry in rawSlots.entries) {
        if (!mediaModelSlotIds.contains(entry.key)) {
          throw FormatException(
            'unknown mediaSlots key: ${entry.key} (expected one of '
            '$mediaModelSlotIds)',
          );
        }
        final value = entry.value;
        if (value is! Map ||
            value.keys.length != 1 ||
            !value.containsKey('model')) {
          throw FormatException(
            'mediaSlots.${entry.key} must be exactly { "model": <id> }',
          );
        }
        slots[entry.key as String] = HostMediaSlotConfig._(
          model: _modelId(value['model'], 'mediaSlots.${entry.key}.model'),
        );
      }
    }
    final rawQuota = json['quota'];
    HostQuotaConfig? quota;
    if (rawQuota != null) {
      if (rawQuota is! Map) throw const FormatException('quota map');
      final status = rawQuota['status'];
      if (status is! int || status < 400 || status > 599) {
        throw const FormatException('quota.status must be 400..599');
      }
      final errorCode = rawQuota['errorCode'];
      if (errorCode is! String ||
          errorCode.trim().isEmpty ||
          errorCode.length > 64 ||
          errorCode.contains(RegExp(r'[<>\x00-\x1f\x7f]'))) {
        throw const FormatException('quota.errorCode must be 1..64 safe chars');
      }
      final urlText = rawQuota['url'];
      Uri? url;
      if (urlText != null) {
        final parsed = Uri.tryParse(urlText.toString());
        if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
          throw const FormatException('quota.url must be an HTTPS link');
        }
        url = parsed;
      }
      quota = HostQuotaConfig._(status: status, errorCode: errorCode, url: url);
    }
    return HostConnectionConfig._(
      name: name,
      baseUrl: baseUrl,
      sessionBridge: HostSessionBridgeConfig._(
        storage: storage as String,
        key: key,
      ),
      defaultModel: defaultModel,
      modelRoles: Map.unmodifiable(roles),
      mediaSlots: Map.unmodifiable(slots),
      quota: quota,
    );
  }

  /// Display name (defaults to the profile's displayName).
  final String name;

  /// OpenAI-compatible base URL of the product's API — same origin as the
  /// profile's apiEndpoint, HTTPS (loopback http for development), no
  /// query, fragment or userinfo.
  final Uri baseUrl;

  /// Where the host page publishes the scoped key (issue #2391).
  final HostSessionBridgeConfig sessionBridge;

  /// The product's default model for new sessions.
  final String defaultModel;

  /// Per-role model defaults; keys are the harness role ids.
  final Map<String, String> modelRoles;

  /// Declared media-slot models; keys are the media slot ids. Undeclared
  /// slots stay unconfigured — nothing is inherited implicitly.
  final Map<String, HostMediaSlotConfig> mediaSlots;

  /// The terminal quota-notice shape, when declared.
  final HostQuotaConfig? quota;

  static Uri _baseUrl(Object? value, Uri apiEndpoint) {
    if (value is! String) {
      throw const FormatException('hostConnection.baseUrl must be a URI');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !_secureEndpoint(uri) ||
        uri.hasQuery ||
        uri.fragment.isNotEmpty) {
      throw FormatException(
        'hostConnection.baseUrl must be a secure endpoint without query or '
        'fragment: $value',
      );
    }
    final sameOrigin =
        uri.scheme == apiEndpoint.scheme &&
        uri.host == apiEndpoint.host &&
        _effectivePort(uri) == _effectivePort(apiEndpoint);
    if (!sameOrigin) {
      throw FormatException(
        'hostConnection.baseUrl must be same-origin with apiEndpoint '
        '(${apiEndpoint.origin}): $value',
      );
    }
    return uri;
  }

  /// Port with the scheme default applied (pure-dart Uri has no
  /// effectivePort; the http package's extension is not available here).
  static int _effectivePort(Uri uri) {
    if (uri.port != 0) return uri.port;
    return uri.scheme == 'https' ? 443 : 80;
  }

  /// The shared endpoint rule, re-exposed for this section's parse.
  static bool _secureEndpoint(Uri uri) {
    if (!uri.hasScheme ||
        uri.host.isEmpty ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '[::1]' ||
            uri.host == '::1');
  }

  static String _safeText(Object? value, String name) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.contains(RegExp(r'[<>\x00-\x1f\x7f]'))) {
      throw FormatException('$name contains unsafe text');
    }
    return value;
  }

  static String _modelId(Object? value, String name) {
    final text = _safeText(value, name);
    if (text.length > 200) {
      throw FormatException('$name must be at most 200 chars');
    }
    return text;
  }
}

/// The same-origin browser storage the host page writes the scoped key to
/// (issue #2391). Only `localStorage` exists in this card.
final class HostSessionBridgeConfig {
  const HostSessionBridgeConfig._({required this.storage, required this.key});

  /// The storage kind: `localStorage` only in this card.
  final String storage;

  /// The same-origin storage key name the host page writes.
  final String key;
}
