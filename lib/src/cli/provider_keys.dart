/// The roles-mode key-name preservation helper and the secure-store token
/// write — split out of `provider_commands.dart` to keep it under the
/// repo's 2800-line size gate. Same library (a `part of`), so the extension
/// sees the class's private members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for provider key names/storage.
extension on AgentCli {
  /// The secure-store key name to keep on a roles-chain pin for
  /// ([provider], [baseUrl]): the current default chain entry for the same
  /// endpoint wins, then the saved custom-provider entry's keyName. Null
  /// when neither knows a scoped key (catalog env names resolve then).
  String? _rolesKeyNameFor(String provider, String? baseUrl) {
    final resolver = config.modelRolesResolver;
    if (resolver == null) return null;
    final refs =
        resolver.config.chainFor(
          defaultModelRole,
          cwd: config.env.cwd,
          homeDir: config.homeDir,
        ) ??
        const <ModelRef>[];
    for (final ref in refs) {
      if (ref.provider == provider &&
          ref.baseUrl == baseUrl &&
          ref.apiKeyName != null) {
        return ref.apiKeyName;
      }
    }
    for (final entry
        in config.customProviders?.entries ?? const <CustomProviderEntry>[]) {
      if (entry.baseUrl == baseUrl && entry.keyName != null) {
        return entry.keyName;
      }
    }
    return null;
  }

  /// The env-resolved stack for a saved entry's key name —
  /// `FA_KEY_COPILOT_<NAME>` + its `_2`… ring (goal/copilot_provider.md:
  /// env-first, works in CI without a secure store). Empty when the host
  /// exposes no environment values. Rings beyond `_9` need the startup
  /// roles resolution, which enumerates the whole environment.
  List<ApiKeyCredential> _envKeyStackFor(String keyName) {
    final read = config.envVarValue;
    if (read == null) return const [];
    final secrets = <String, String>{
      for (var i = 2; i <= 9; i++)
        if (read.call('${keyName}_$i') case final value? when value.isNotEmpty)
          '${keyName}_$i': value,
    };
    if (read.call(keyName) case final base? when base.isNotEmpty) {
      secrets[keyName] = base;
    }
    return collectKeyStack(secrets, keyName);
  }

  /// The host-scoped store key name for a NON-catalog-default endpoint
  /// (CodeMie SSO, DIAL, self-hosted) — where SSO-cookie saves put their
  /// cookie even when no registry entry recorded an explicit keyName. Null
  /// for the catalog default endpoint (its env names keep priority) and for
  /// unknown providers. Used ONLY by the model-switch pins: the roles
  /// resolver must bind the endpoint's OWN key, never the catalog env name
  /// (the "no usable chain entry: set OPENAI_API_KEY" bug).
  String? _scopedKeyNameForNonDefault(String provider, String? baseUrl) {
    if (baseUrl == null) return null;
    final spec = catalogProvider(provider);
    if (spec != null && baseUrl == spec.defaultBaseUrl) return null;
    return CustomProviderRegistry.keyNameFor(baseUrl);
  }

  /// Persists an explicit `/provider` token in the platform secure store
  /// so future starts resolve it without env vars. Returns the store label
  /// on success, null when secure storage is unavailable (the token then
  /// stays session-only). The entry name is [keyName] (registry entries use
  /// their own), defaulting to the endpoint-scoped name for [baseUrl] —
  /// NOT the spec's shared env name, so a key for one endpoint can never be
  /// picked up by another (the stale-OPENAI_API_KEY-on-kimi footgun).
  Future<String?> _storeProviderToken(
    ProviderSpec spec,
    String baseUrl,
    String token, {
    String? keyName,
  }) async {
    final keys = config.secureKeys;
    if (keys == null || !keys.available) return null;
    final name = keyName ?? CustomProviderRegistry.keyNameFor(baseUrl);
    if (await keys.save(name, token)) {
      config.onSecretStored?.call(name, token);
      return keys.label;
    }
    io.writeln(
      'note: could not save the key to ${keys.label} (locked or managed '
      'keychain?) — it applies to this session only',
    );
    return null;
  }
}
