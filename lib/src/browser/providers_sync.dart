/// Providers sync payload (issue #34 item 3, §S6): the metadata the CLI
/// pushes to a paired extension right after the bridge `welcome` frame.
///
/// Two key modes:
///
/// - `proxy` (DEFAULT): keys never leave the CLI. The payload carries
///   metadata only; the extension routes LLM calls through the bridge
///   (`llmReq`/`llmRes`), which injects auth server-side.
/// - `copy` (OPT-IN via `/browser connect --copy-keys`): a separate
///   top-level `keys` field transfers each entry's key ONCE over the
///   loopback + one-time-token channel; the bridge wipes its staged copy
///   as soon as the client acks. Keys NEVER ride inside the per-provider
///   metadata — logged/serialized metadata paths stay key-free.
///
/// Pure Dart, additive-versioned: decode ignores unknown fields and
/// answers `null` (not an exception) on shapes it cannot trust, so an old
/// CLI + new extension (or vice versa) degrades gracefully.
library;

import '../cli/custom_providers.dart';

/// Payload version. Bump only for breaking shape changes; additive
/// fields keep 1.
const int providersSyncVersion = 1;

/// The hello `caps` entry a client advertises to receive the sync push.
/// Older extensions do not send it and never see the frame.
const String providersSyncCapability = 'providers-sync';

/// Key-handling mode of one sync push.
enum ProvidersSyncMode {
  /// Keys stay on the CLI; LLM traffic relays through the bridge.
  proxy('proxy'),

  /// Keys transfer once in the `keys` field; bridge copy wiped on ack.
  copy('copy');

  const ProvidersSyncMode(this.wire);

  /// The exact string on the wire.
  final String wire;

  /// Parses a wire mode; null when the peer invented one.
  static ProvidersSyncMode? fromWire(String wire) {
    for (final mode in values) {
      if (mode.wire == wire) return mode;
    }
    return null;
  }
}

/// Provenance marker stamped on every synced entry:
/// `synced-from-cli@<host>`.
String providersSyncProvenance(String hostname) => 'synced-from-cli@$hostname';

/// One synced provider's metadata (never a key).
final class ProvidersSyncProvider {
  const ProvidersSyncProvider({
    required this.name,
    required this.apiType,
    required this.baseUrl,
    required this.modelId,
    required this.provenance,
  });

  /// Decodes one entry; null on a shape it cannot trust (missing name or
  /// baseUrl). Unknown fields ignored.
  static ProvidersSyncProvider? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final baseUrl = json['baseUrl'];
    if (name is! String || name.isEmpty) return null;
    if (baseUrl is! String || baseUrl.isEmpty) return null;
    return ProvidersSyncProvider(
      name: name,
      baseUrl: baseUrl,
      apiType: json['apiType'] is String ? json['apiType'] as String : '',
      modelId: json['modelId'] is String ? json['modelId'] as String : '',
      provenance: json['provenance'] is String
          ? json['provenance'] as String
          : '',
    );
  }

  final String name;
  final String apiType;
  final String baseUrl;
  final String modelId;

  /// `synced-from-cli@<host>` — where this entry came from.
  final String provenance;

  Map<String, dynamic> toJson() => {
    'name': name,
    'apiType': apiType,
    'baseUrl': baseUrl,
    'modelId': modelId,
    'provenance': provenance,
  };
}

/// The full `providersSync` frame payload.
final class ProvidersSyncPayload {
  const ProvidersSyncPayload({
    required this.mode,
    required this.host,
    required this.providers,
    this.keys = const {},
  });

  /// Decodes a payload; null on a shape it cannot trust (bad version,
  /// unknown mode, non-object providers). Unknown/extra fields ignored —
  /// additive versioning means a newer peer's extras never break us.
  static ProvidersSyncPayload? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    if (json['version'] != providersSyncVersion) return null;
    final mode = ProvidersSyncMode.fromWire(
      json['mode'] is String ? json['mode'] as String : '',
    );
    if (mode == null) return null;
    final host = json['host'];
    if (host is! String || host.isEmpty) return null;
    final rawProviders = json['providers'];
    if (rawProviders is! List) return null;
    final providers = <ProvidersSyncProvider>[];
    for (final entry in rawProviders) {
      if (entry is! Map<String, dynamic>) return null;
      final provider = ProvidersSyncProvider.fromJson(entry);
      if (provider == null) return null;
      providers.add(provider);
    }
    // Keys ride only in copy mode, in their own field — never inline.
    final rawKeys = json['keys'];
    final keys = <String, String>{};
    if (rawKeys is Map<String, dynamic>) {
      rawKeys.forEach((name, key) {
        if (key is String && key.isNotEmpty) keys[name] = key;
      });
    }
    return ProvidersSyncPayload(
      mode: mode,
      host: host,
      providers: providers,
      keys: mode == ProvidersSyncMode.copy ? keys : const {},
    );
  }

  final ProvidersSyncMode mode;
  final String host;
  final List<ProvidersSyncProvider> providers;

  /// Copy mode only: `provider name → key` for entries whose key the CLI
  /// actually resolved. Empty in proxy mode.
  final Map<String, String> keys;

  Map<String, dynamic> toJson() => {
    'version': providersSyncVersion,
    'mode': mode.wire,
    'host': host,
    'providers': [for (final p in providers) p.toJson()],
    if (mode == ProvidersSyncMode.copy && keys.isNotEmpty)
      'keys': Map<String, String>.of(keys),
  };
}

/// Builds the sync payload from the CLI's saved custom providers.
///
/// Pure: the caller resolves keys (copy mode) and passes them in — this
/// function never touches a key store. Entries without a resolved key
/// still sync (metadata is harmless); they simply carry no key.
ProvidersSyncPayload buildProvidersSync(
  Iterable<CustomProviderEntry> entries, {
  required ProvidersSyncMode mode,
  required String hostname,
  Map<String, String> keys = const {},
}) {
  return ProvidersSyncPayload(
    mode: mode,
    host: hostname,
    providers: [
      for (final entry in entries)
        ProvidersSyncProvider(
          name: entry.name,
          apiType: entry.apiType,
          baseUrl: entry.baseUrl,
          modelId: entry.modelId,
          provenance: providersSyncProvenance(hostname),
        ),
    ],
    // Proxy mode never carries keys — a caller passing them anyway
    // (defensive) must not leak them onto the wire.
    keys: mode == ProvidersSyncMode.copy ? keys : const {},
  );
}
