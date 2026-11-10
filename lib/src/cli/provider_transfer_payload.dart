/// The `/provider export` / `/provider import` one-provider container
/// payload (issue #2090 UC2): the CURRENT provider's config + credential in
/// the existing `.fahx` envelope (the envelope/KDF/EtM bytes are shared
/// with `fa config export-providers`; this payload is a different shape
/// inside it, marked by [providerTransferPayloadKind]).
///
/// Payload JSON:
///
/// ```json
/// {"payloadKind":"provider-transfer","version":1,"exportedAt":"...",
///  "provider":{ "name":..,"apiType":..,"baseUrl":..,"modelId":.., ...
///               } | {"catalog":"anthropic","baseUrl":?,"modelId":..},
///  "key":{"name":"FA_KEY_...","kind":"api-key|oauth|sso","value":..}}
/// ```
///
/// `provider` with an `apiType` field is a saved custom-provider entry
/// (the registry `customProviders:` yaml shape); one with a `catalog`
/// field is a catalog preset selection. Pure: no dart:io — the REPL flow
/// in `provider_export_command.dart` (a `part of agent_cli.dart`) applies
/// it through the existing storage paths.
library;

import '../exceptions.dart';
import '../providers/fahx_codec.dart';
import 'custom_providers.dart';

/// The payload-kind marker distinguishing a one-provider transfer
/// container from the legacy all-providers `.fahx` payload.
const String providerTransferPayloadKind = 'provider-transfer';

/// Payload version (the ENVELOPE version stays 1 — goldens keep importing).
const int providerTransferPayloadVersion = 1;

/// How the transferred credential authenticates.
enum ProviderTransferKeyKind {
  /// A plain API key / JWT Bearer secret (goes into an env var).
  apiKey('api-key'),

  /// An OAuth blob in its import shape (ChatGPT credentials JSON, a
  /// Copilot GitHub token).
  oauth('oauth'),

  /// An SSO blob (the CodeMie cookie header value).
  sso('sso');

  const ProviderTransferKeyKind(this.wireName);

  /// The JSON spelling.
  final String wireName;

  static ProviderTransferKeyKind parse(String value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    throw FahxException(
      'provider-transfer payload key kind "$value" is not one of '
      'api-key/oauth/sso',
    );
  }
}

/// One transferred credential: the destination slot [name] (an
/// env-readable store key: `FA_KEY_<HOST>[_<NAME>]`, the spec's primary
/// env name, or an OAuth slot), its [kind], and the secret [value].
final class ProviderTransferKey {
  const ProviderTransferKey({
    required this.name,
    required this.kind,
    required this.value,
  });

  final String name;
  final ProviderTransferKeyKind kind;
  final String value;

  Map<String, Object?> toJson() => {
    'name': name,
    'kind': kind.wireName,
    'value': value,
  };

  static ProviderTransferKey parse(Object? raw) {
    if (raw is! Map) throw const FahxException('payload key is malformed');
    final name = raw['name'];
    final kind = raw['kind'];
    final value = raw['value'];
    if (name is! String ||
        name.isEmpty ||
        kind is! String ||
        value is! String ||
        value.isEmpty) {
      throw const FahxException('payload key is malformed');
    }
    return ProviderTransferKey(
      name: name,
      kind: ProviderTransferKeyKind.parse(kind),
      value: value,
    );
  }
}

/// The decoded one-provider container.
final class ProviderTransferBundle {
  const ProviderTransferBundle({
    this.entry,
    this.catalog,
    this.baseUrl,
    required this.modelId,
    this.key,
    this.exportedAt,
  });

  /// The saved custom-provider entry (null for a catalog preset subject).
  final CustomProviderEntry? entry;

  /// The catalog spec name for a catalog preset subject (null for an
  /// entry subject). Exactly one of [entry]/[catalog] is non-null.
  final String? catalog;

  /// The endpoint the session ran on (null = the catalog spec's default).
  final String? baseUrl;

  /// The last-used model id.
  final String modelId;

  /// The credential, or null when the provider ran keyless.
  final ProviderTransferKey? key;

  /// Export timestamp (informational only).
  final String? exportedAt;

  /// Encodes into the payload map (the plaintext inside the envelope).
  Map<String, dynamic> toJson() => {
    'payloadKind': providerTransferPayloadKind,
    'version': providerTransferPayloadVersion,
    'exportedAt': ?exportedAt,
    'provider': entry != null
        ? entry!.toYaml()
        : {'catalog': catalog, 'baseUrl': ?baseUrl, 'modelId': modelId},
    'key': ?key?.toJson(),
  };

  /// Decodes + validates a payload map. Every problem is a loud
  /// [FahxException] (wrong passphrase/tamper surfaces earlier, at the
  /// envelope; this catches a wrong-kind container with zero writes).
  static ProviderTransferBundle parse(Object? payload) {
    if (payload is! Map) {
      throw const FahxException('not a provider-transfer container');
    }
    if (payload['payloadKind'] != providerTransferPayloadKind) {
      // The legacy all-providers `.fahx` payload lands here: name the
      // difference instead of a bare "malformed".
      if (payload['providers'] is List) {
        throw const FahxException(
          'this is a legacy all-providers .fahx export — use '
          '`fa config` headless import for it; /provider import takes a '
          'one-provider /provider export container',
        );
      }
      throw const FahxException('not a provider-transfer container');
    }
    if (payload['version'] != providerTransferPayloadVersion) {
      throw FahxException(
        'unsupported provider-transfer payload version: '
        '${payload['version']}',
      );
    }
    final provider = payload['provider'];
    if (provider is! Map) {
      throw const FahxException('provider-transfer payload is malformed');
    }
    final key = payload['key'] == null
        ? null
        : ProviderTransferKey.parse(payload['key']);
    final exportedAt = payload['exportedAt'];
    if (provider['apiType'] is String) {
      CustomProviderEntry entry;
      try {
        entry = CustomProviderEntry.fromYaml(provider);
      } on ConfigException catch (error) {
        throw FahxException(
          'provider-transfer payload entry is malformed: ${error.message}',
        );
      }
      return ProviderTransferBundle(
        entry: entry,
        modelId: entry.modelId,
        key: key,
        exportedAt: exportedAt is String ? exportedAt : null,
      );
    }
    final catalog = provider['catalog'];
    final modelId = provider['modelId'];
    if (catalog is! String || catalog.isEmpty || modelId is! String) {
      throw const FahxException('provider-transfer payload is malformed');
    }
    final baseUrl = provider['baseUrl'];
    return ProviderTransferBundle(
      catalog: catalog,
      baseUrl: baseUrl is String && baseUrl.isNotEmpty ? baseUrl : null,
      modelId: modelId,
      key: key,
      exportedAt: exportedAt is String ? exportedAt : null,
    );
  }
}
