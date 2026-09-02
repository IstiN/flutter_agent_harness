/// The startup banner and the key-status/hint lines (`_printBanner`, the
/// `_keyStatus*`/`_envKey*`/`_storedKey*` helpers, `_errorLine` and the
/// auth-hint family). Split out of `agent_cli.dart` to keep that file
/// under the repo's 2800-line size gate. Same library (a `part of`), so
/// the extension sees the class's private members.
part of 'agent_cli.dart';

/// Banner + key-status members of [AgentCli].
extension on AgentCli {
  Future<void> _printBanner() async {
    final model = _agent.state.model;
    final metadata = await _session!.getMetadata();
    io.writeln(
      '${_style.bold(_style.teal('>_'))}${_style.bold('Fa')} '
      '${_style.dim('v$_version')}',
    );
    io.writeln(
      _style.dim('escape interrupt · ctrl+c clear/exit · / commands · ! bash'),
    );
    io.writeln(_style.dim('Press /help to show full commands and resources.'));
    io.writeln('');
    io.writeln(_style.bold('[Context]'));
    io.writeln('  ${_env.cwd}');
    io.writeln('');
    io.writeln(_style.bold('[Model]'));
    io.writeln('  ${model.id} (${model.api})');
    io.writeln('  endpoint: ${model.baseUrl}');
    final keyStatus = _keyStatusLine(model);
    if (keyStatus != null) {
      io.writeln(
        keyStatus.startsWith('key: no key set')
            ? '  ${_style.yellow(keyStatus)}'
            : '  $keyStatus',
      );
    }
    io.writeln('');
    io.writeln(_style.bold('[Session]'));
    final sessionName = await _session?.getSessionName();
    if (sessionName != null && sessionName.isNotEmpty) {
      io.writeln('  $sessionName');
    }
    io.writeln('  ${metadata.path}');
  }

  /// The banner's key-status line: the name of the env var supplying the
  /// provider key (never the value), or a "no key set" warning when the
  /// provider expects a key the host does not have. Null when the provider
  /// declares no key env vars (custom/test providers) — no warning then —
  /// and null for a custom endpoint (base URL other than the catalog
  /// default), which may legitimately run keyless (local llama.cpp/Ollama/
  /// LM Studio servers).
  ///
  /// Legacy mode reads the names by provider KIND, matching the executable's
  /// key lookup: `openai-completions` accepts OPENROUTER_API_KEY/
  /// OPENAI_API_KEY even on custom endpoints, where the model's provider
  /// flips to `openai`. Roles mode keys per resolved chain entry, so the
  /// live model's provider names are the right ones there. An explicit
  /// `/provider` token has no env var to name and reads as "provided" — the
  /// value is never printed.
  String? _keyStatusLine(Model model) {
    final spec = catalogProvider(_rolesDriven ? model.provider : _providerKind);
    final names = spec?.apiKeyEnvNames;
    if (names == null || names.isEmpty) return null;
    // An explicit /provider token (or a saved custom entry's key) IS the
    // active key: name its store slot. The value is never printed.
    if (!_rolesDriven && _explicitToken) return _explicitTokenKeyStatus(model);
    return _resolvedKeyStatus(model, spec, names);
  }

  /// Key status when an explicit token or saved-entry key is in play.
  String _explicitTokenKeyStatus(Model model) {
    final entryKey = _activeCustomKeyName();
    if (_hasStoredKey(entryKey)) return 'key: $entryKey';
    return _scopedTokenKeyStatus(model);
  }

  /// Whether [name] names a key present in the secure store.
  bool _hasStoredKey(String? name) =>
      name != null && config.secureKeys?.read(name) != null;

  /// Key status fallback for an explicit token: the host-scoped store slot,
  /// or the anonymous "provided" marker.
  String _scopedTokenKeyStatus(Model model) {
    final scoped = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (config.secureKeys?.read(scoped) != null) return 'key: $scoped';
    return 'key: provided';
  }

  /// Key status from the resolution order: genuine environment values first
  /// (they differ from the store's entry); then the active custom entry's
  /// slot (multi-account entries use name-scoped ones), the host-scoped
  /// slot, and legacy env-name entries (env or store — indistinguishable
  /// here).
  String? _resolvedKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    final keys = config.secureKeys;
    final envKey = _envKeyStatus(names);
    if (envKey != null) return envKey;
    final entryKey = _activeCustomKeyName();
    if (entryKey != null && keys?.read(entryKey) != null) {
      return 'key: $entryKey';
    }
    final scopedName = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (keys?.read(scopedName) != null) return 'key: $scopedName';
    return _fallbackKeyStatus(model, spec, names);
  }

  /// Key status fallback: any legacy env-name entry, else the "no key set"
  /// guidance (null for non-default endpoints without a key).
  String? _fallbackKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    final set = names
        .where((name) => config.envVarIsSet?.call(name) ?? false)
        .firstOrNull;
    if (set != null) return 'key: $set';
    if (spec != null && model.baseUrl != spec.defaultBaseUrl) return null;
    return 'key: no key set (want ${names.first})';
  }

  /// The first env-name holding a genuine environment value (differs from
  /// the store's entry), as a `key: <name>` status, or null.
  String? _envKeyStatus(List<String> names) {
    final keys = config.secureKeys;
    for (final name in names) {
      final value = config.envVarValue?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return 'key: $name';
      }
    }
    return null;
  }

  /// The active saved custom provider's secure-store key name, or null when
  /// none is active (or the entry is keyless).
  String? _activeCustomKeyName() {
    final name = _activeCustomName;
    if (name == null) return null;
    return config.customProviders?.find(name)?.keyName;
  }

  /// Resolves a named secret (env first, then the secure store) for media
  /// slot `apiKeyName` overrides. Returns null when the name is unknown.
  Future<String?> _resolveMediaKey(String name) async {
    final value = config.envVarValue?.call(name);
    if (value != null && value.isNotEmpty) return value;
    return config.secureKeys?.read(name);
  }

  /// The `error:` diagnostic line for a failed run. Provider JSON blobs
  /// (OpenRouter wraps upstream errors in nested JSON) are compacted to the
  /// most specific message. A connection-level failure ("Connection
  /// refused" — a SocketException, or a package:http ClientException
  /// wrapping one; the provider adapters reduce both to their message
  /// string, so detection is textual) appends the endpoint hint: the
  /// effective base URL from the config or `--base-url` is almost always
  /// the thing to fix then. A 401-class auth failure appends the key
  /// diagnostic: which env var is in play, whether an environment value is
  /// shadowing a DIFFERENT stored key (env wins over the secure store — the
  /// classic stale-export footgun), or that no key resolved at all.
  String _errorLine(String message) {
    final compact = compactProviderError(message);
    if (_isAuthError(compact)) {
      return _style.red('error: $compact${_authHint()}');
    }
    if (!compact.toLowerCase().contains('connection refused')) {
      return _style.red('error: $compact');
    }
    return _style.red(
      'error: $compact — check the endpoint in ~/.fah/config.yaml '
      '(baseUrl: ${_agent.state.model.baseUrl}) or pass --base-url',
    );
  }

  /// 401-class detection across provider wordings (OpenAI/OpenRouter "401:
  /// API Key invalid", Anthropic "authentication_error", plain
  /// "Unauthorized").
  bool _isAuthError(String compact) {
    final lower = compact.toLowerCase();
    return RegExp(r'\b401\b').hasMatch(compact) ||
        lower.contains('unauthorized') ||
        lower.contains('authentication_error') ||
        (lower.contains('api key') && lower.contains('invalid'));
  }

  /// The ` — ...` suffix for [_errorLine] on auth failures. Never prints key
  /// material — names and sources only. Mirrors the provider key resolution
  /// order: genuine environment value → endpoint-scoped store entry →
  /// legacy env-name store entry.
  String _authHint() {
    if (_rolesDriven) {
      return ' — roles mode reads keys from the environment only; check '
          'the chain env vars in ~/.fah/config.yaml';
    }
    final spec = catalogProvider(_providerKind);
    final names = spec?.apiKeyEnvNames;
    final baseUrl = _agent.state.model.baseUrl;
    if (names == null || names.isEmpty) {
      return ' — check the credentials for $baseUrl';
    }
    final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
    // A genuine environment key in play: warn when it shadows a different
    // same-name store entry, else name it as the source.
    final envHint = _envActiveHint(names, baseUrl);
    if (envHint != null) return envHint;
    // Endpoint-scoped store key (what /provider and the wizard write): the
    // active custom entry's name-scoped slot first, then the host-scoped
    // one.
    final entryKey = _activeCustomKeyName();
    final scoped = entryKey ?? scopedName;
    final storedHint = _storedKeyHint(scoped, baseUrl);
    if (storedHint != null) return storedHint;
    // Legacy env-name store key (older versions wrote these).
    final legacy = names
        .where((name) => (config.envVarValue?.call(name) ?? '').isNotEmpty)
        .firstOrNull;
    if (legacy != null) return _storeHintMessage(legacy, baseUrl);
    return _noKeyHint(entryKey, baseUrl, spec, scopedName, names);
  }

  /// The hint naming a secure-store key as the source.
  String _storeHintMessage(String name, String baseUrl) {
    final label = config.secureKeys?.label ?? 'secure store';
    return ' — the key came from the $label ($name); verify it is valid '
        'for $baseUrl or replace it with /key set $name <value>';
  }

  /// The fallback hint when no key resolved (or the token was rejected).
  String _noKeyHint(
    String? entryKey,
    String baseUrl,
    ProviderSpec? spec,
    String scopedName,
    List<String> names,
  ) {
    final suggested =
        entryKey ??
        (baseUrl != spec?.defaultBaseUrl ? scopedName : names.first);
    return _explicitToken
        ? ' — the /provider token was rejected; set a fresh one with '
              '/key set $suggested <value>'
        : ' — no key set; store one with /key set $suggested <value>';
  }

  /// The hint for a genuine environment key, or null when none is in play.
  String? _envActiveHint(List<String> names, String baseUrl) {
    final envActive = _activeEnvKeyName(names);
    if (envActive == null) return null;
    return _envKeyHint(envActive, baseUrl);
  }

  /// The first env-name holding a genuine environment key (differs from the
  /// same-name store entry), or null.
  String? _activeEnvKeyName(List<String> names) {
    final keys = config.secureKeys;
    return names.where((name) {
      final value = config.envVarValue?.call(name);
      return value != null && value.isNotEmpty && value != keys?.read(name);
    }).firstOrNull;
  }

  /// The hint for a genuine environment key: the shadowing warning when a
  /// DIFFERENT same-name store entry exists, else the source note.
  String _envKeyHint(String envActive, String baseUrl) {
    final keys = config.secureKeys;
    final storedTwin = keys?.read(envActive);
    if (storedTwin != null && storedTwin.isNotEmpty) {
      final label = keys?.label ?? 'secure store';
      return ' — the environment variable $envActive shadows a DIFFERENT '
          'key in the $label; the env value is the one sent — fix or '
          'unset it, or /key delete $envActive';
    }
    return ' — the key came from the environment ($envActive); verify it '
        'is valid for $baseUrl or replace it with '
        '/key set $envActive <value>';
  }

  /// The hint for a key read from the secure store, or null when the slot is
  /// empty.
  String? _storedKeyHint(String name, String baseUrl) {
    if (config.secureKeys?.read(name) == null) return null;
    return _storeHintMessage(name, baseUrl);
  }
}
