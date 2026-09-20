/// The custom-provider registry: user-saved providers (api type + endpoint
/// + optional key reference + last-used model) persisted in the
/// `customProviders:` section of `~/.fah/config.yaml`.
///
/// A registry entry is what the `/provider` picker lists above the catalog
/// presets and what the `/provider custom` wizard appends to; switching to
/// an entry restores its last-used model, and `/model` while an entry is
/// active writes the new model id back (per-provider model memory).
library;

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart';

/// The api types a custom provider can take (the adapter dialect), mapping
/// one-to-one to catalog specs. Includes OAuth/SSO-backed catalog providers
/// (openrouter, codemie) — their connect flows save registry entries so
/// connected providers show in the `/provider` picker — and `kimi`, whose
/// `/provider kimi` key flow saves a named entry per account.
const customProviderApiTypes = [
  'openai',
  'anthropic',
  'google',
  'dial',
  'openrouter',
  'minimax',
  'zai',
  'aiin',
  'kimi',
  'chatgpt',
  'copilot',
];

/// How a saved custom provider authenticates. Distinguishes regular API-key
/// entries from SSO/JWT-backed ones (e.g. CodeMie) so the CLI can pick the
/// right auth path when switching to a saved entry.
enum CustomProviderAuthMethod {
  /// Regular API-key or env-resolved auth (default).
  apiKey,

  /// Browser-based SSO (CodeMie cookie auth).
  sso,

  /// JWT Bearer token (CodeMie headless auth).
  jwt,
}

/// One saved custom provider.
final class CustomProviderEntry {
  /// Creates an entry. [keyName] is the secure-store/env name holding the
  /// API key (null = keyless); [modelId] is the last-used model.
  /// [authMethod] selects the auth path for SSO/JWT providers.
  CustomProviderEntry({
    required this.name,
    required this.apiType,
    required this.baseUrl,
    required this.modelId,
    this.keyName,
    this.authMethod = CustomProviderAuthMethod.apiKey,
  });

  /// Parses one yaml map from the `customProviders:` list. Throws
  /// [ConfigException] on bad shapes (bad config must surface, never
  /// silently vanish).
  factory CustomProviderEntry.fromYaml(Object? node) {
    if (node is! Map) {
      throw ConfigException('customProviders entries must be maps, got: $node');
    }
    String requireString(String field) {
      final value = node[field];
      if (value is! String || value.isEmpty) {
        throw ConfigException(
          'customProviders entry needs a non-empty "$field"',
        );
      }
      return value;
    }

    final apiType = requireString('apiType');
    if (!customProviderApiTypes.contains(apiType)) {
      throw ConfigException(
        'customProviders entry "$apiType" is not a supported apiType '
        '(${customProviderApiTypes.join(', ')})',
      );
    }
    final keyName = node['keyName'];
    final authMethod = _parseAuthMethod(node['authMethod']);
    return CustomProviderEntry(
      name: requireString('name'),
      apiType: apiType,
      baseUrl: requireString('baseUrl'),
      modelId: requireString('modelId'),
      keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
      authMethod: authMethod,
    );
  }

  static CustomProviderAuthMethod _parseAuthMethod(Object? value) {
    if (value is! String) return CustomProviderAuthMethod.apiKey;
    switch (value) {
      case 'sso':
        return CustomProviderAuthMethod.sso;
      case 'jwt':
        return CustomProviderAuthMethod.jwt;
      default:
        return CustomProviderAuthMethod.apiKey;
    }
  }

  /// Display/lookup name (derived from the endpoint host at creation).
  final String name;

  /// The adapter dialect: `openai`, `anthropic`, or `google` (catalog spec
  /// names, see [providerCatalog]).
  final String apiType;

  /// The endpoint base URL.
  final String baseUrl;

  /// The secure-store/env name holding the API key, or null when keyless.
  String? keyName;

  /// How this entry authenticates. Used to pick the right path when switching
  /// to saved SSO/JWT providers.
  CustomProviderAuthMethod authMethod;

  /// The last-used model id (rewritten on `/model` switches while active).
  String modelId;

  /// Serializes to the yaml section's map shape.
  Map<String, String> toYaml() {
    return {
      'name': name,
      'apiType': apiType,
      'baseUrl': baseUrl,
      'keyName': ?keyName,
      'authMethod': authMethod.name,
      'modelId': modelId,
    };
  }

  /// The catalog spec backing this entry's adapter dialect.
  ProviderSpec get spec => providerCatalog[apiType]!;
}

/// Whether [name] is reserved for a built-in catalog provider
/// (case-insensitive): an entry named `openai`/`anthropic`/… shadows
/// `/provider <name>` routing — issue #221's ghost "openai". Reserved
/// names are rejected at [CustomProviderRegistry.add], dropped at config
/// load, and filtered out of every merged write.
bool isReservedCustomProviderName(String name) =>
    providerCatalog.containsKey(name.toLowerCase());

/// Auth-domain aliases (#706): several spellings can name the SAME
/// provider account — the ChatGPT OAuth flow derives `chatgpt.com` from
/// the endpoint host while the catalog provider is `chatgpt`, so one
/// auth domain ended up with two picker identities, both marked current.
/// The map folds an alias spelling onto its canonical id; entries keep
/// their registry name (switching, key slots), identities canonicalize.
const Map<String, String> providerNameAliases = {'chatgpt.com': 'chatgpt'};

/// The canonical provider identity of [name]: alias spellings fold onto
/// their canonical id (case-insensitive); unknown names map to
/// themselves (lowercased). One auth domain — one identity, across the
/// registry, the picker rows, and the current marker.
String canonicalProviderName(String name) {
  final lower = name.trim().toLowerCase();
  return providerNameAliases[lower] ?? lower;
}

/// The pattern a typed saved-provider name must match: starts with a
/// letter or digit, then letters/digits/`. _ + -`. Anything else either
/// breaks `/provider <name>` argument routing (spaces, slashes) or is a
/// yaml indicator that corrupts the bare `name:` scalar in config.yaml
/// (issue #555: a name of `?` made the next config load throw). `@` and
/// `:` stay legal — the aiin connect names entries by account email and
/// [CustomProviderRegistry.deriveName] appends `:port` to non-default
/// ports; the yaml quoting writer is the backstop for both.
final _usableProviderNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+:@-]*$');

/// Whether [name] is a usable saved-provider name; the name prompts
/// re-prompt otherwise. Empty answers never reach this — they take the
/// flow's default name.
bool isUsableCustomProviderName(String name) =>
    _usableProviderNamePattern.hasMatch(name);

/// The merge-before-write union for the `customProviders:` section (issue
/// #221): [caller] is the saving process's intended list, [onDisk] the
/// freshly re-read list. Caller's entries win per name (case-insensitive)
/// — an in-flight edit lands — while on-disk entries the caller never
/// loaded survive (no stale-snapshot clobber). Reserved (catalog-named)
/// entries are dropped from the result so a ghost can never persist.
List<CustomProviderEntry> mergeCustomProviderEntries(
  List<CustomProviderEntry> caller,
  List<CustomProviderEntry> onDisk,
) {
  final callerNames = {for (final e in caller) e.name.toLowerCase()};
  return [
    for (final e in caller)
      if (!isReservedCustomProviderName(e.name)) e,
    for (final e in onDisk)
      if (!callerNames.contains(e.name.toLowerCase()) &&
          !isReservedCustomProviderName(e.name))
        e,
  ];
}

/// The live list of saved custom providers (shared by the CLI, which
/// mutates it, and the executable, which persists it).
final class CustomProviderRegistry {
  /// Creates a registry over [entries] (a live, mutable list). Same-auth-
  /// domain records (alias spellings of one canonical id, #706 — e.g. a
  /// hand-edited `chatgpt` ghost next to the OAuth-minted `chatgpt.com`)
  /// merge onto ONE record: fields the survivor lacks are inherited from
  /// the twin (union — nothing dropped), conflicts keep the survivor's
  /// value, and a note lands in [mergeNotes]. A reserved-named ghost
  /// (e.g. `chatgpt`, which would shadow `/provider` routing) never
  /// survives — the non-reserved twin wins even when it came later.
  CustomProviderRegistry(List<CustomProviderEntry> entries)
    : this._loaded(_mergeOnLoad(entries));

  CustomProviderRegistry._loaded(
    ({List<CustomProviderEntry> entries, List<String> notes}) loaded,
  ) : entries = loaded.entries,
      mergeNotes = loaded.notes;

  /// All saved entries, in insertion order.
  final List<CustomProviderEntry> entries;

  /// Human-readable notes from the load-time same-domain merge (#706).
  /// Each note names the record that was folded and the record that
  /// actually survived (a ghost-first load swaps both — see
  /// [_mergeOnLoad]).
  final List<String> mergeNotes;

  /// The load-time merge result: one record per canonical identity; a
  /// reserved-named ghost (e.g. `chatgpt`, which would shadow
  /// `/provider` routing) yields to a non-reserved twin of the same
  /// domain even when the ghost came first. The merge and its notes are
  /// ONE pass over the source, so every note names the record that
  /// actually survives — a ghost-first load keeps `chatgpt.com` and the
  /// note must say so, not the ghost it displaced.
  static ({List<CustomProviderEntry> entries, List<String> notes}) _mergeOnLoad(
    List<CustomProviderEntry> source,
  ) {
    final survivors = <String, CustomProviderEntry>{};
    final order = <String>[];
    final notes = <String>[];
    for (final entry in source) {
      final id = canonicalProviderName(entry.name);
      final existing = survivors[id];
      if (existing == null) {
        survivors[id] = entry;
        order.add(id);
        continue;
      }
      // Ghost-first takeover: a reserved-named survivor can never
      // receive logins (name prompts and `add` reject it) nor survive a
      // merged write, so the non-reserved twin becomes the survivor.
      final ghostFirst =
          isReservedCustomProviderName(existing.name) &&
          !isReservedCustomProviderName(entry.name);
      final survivor = ghostFirst ? entry : existing;
      final twin = ghostFirst ? existing : entry;
      _unionOnto(survivor, twin);
      survivors[id] = survivor;
      notes.add(
        'merged duplicate provider record "${twin.name}" onto '
        '"${survivor.name}" (same auth domain)',
      );
    }
    return (entries: [for (final id in order) survivors[id]!], notes: notes);
  }

  /// Folds [twin]'s missing fields into [survivor] (union; survivor's
  /// own values win conflicts). Returns [survivor].
  static CustomProviderEntry _unionOnto(
    CustomProviderEntry survivor,
    CustomProviderEntry twin,
  ) {
    if (survivor.keyName == null && twin.keyName != null) {
      survivor.keyName = twin.keyName;
    }
    return survivor;
  }

  /// Finds an entry by [name] (case-insensitive), or null. Alias
  /// spellings resolve onto the canonical record: `find('chatgpt.com')`
  /// and `find('chatgpt')` both land on the one same-domain entry.
  CustomProviderEntry? find(String name) {
    final lower = name.toLowerCase();
    for (final entry in entries) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    final canonical = canonicalProviderName(name);
    for (final entry in entries) {
      if (canonicalProviderName(entry.name) == canonical) return entry;
    }
    return null;
  }

  /// Adds (or replaces, on name clash) [entry]. Throws [ConfigException]
  /// when the entry is named after a built-in catalog provider — such an
  /// entry shadows `/provider <name>` routing and is exactly the ghost
  /// "openai" of issue #221; the interactive name prompts reject these
  /// names already, this is the last line of defense for flows that
  /// construct entries directly.
  void add(CustomProviderEntry entry) {
    if (isReservedCustomProviderName(entry.name)) {
      throw ConfigException(
        '"${entry.name}" is a built-in provider name — a saved custom '
        'entry with that name shadows /provider ${entry.name} routing; '
        'pick another name',
      );
    }
    final existing = find(entry.name);
    if (existing != null) entries.remove(existing);
    entries.add(entry);
  }

  /// Records the last-used model for the entry named [name] (no-op when
  /// absent).
  void updateModel(String name, String modelId) {
    find(name)?.modelId = modelId;
  }

  /// Derives a unique display name from [baseUrl]'s host (and non-default
  /// port), avoiding catalog provider names and existing entries:
  /// `localhost:11434`, `api.acme.com`, `api.acme.com-2`, ...
  String deriveName(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) host = 'custom';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    final candidate = port != null && port != defaultPort
        ? '$host:$port'
        : host;
    return _dedupe(candidate);
  }

  String _dedupe(String candidate) {
    final reserved = <String>{'custom', ...providerCatalog.keys};
    var name = candidate;
    var suffix = 2;
    while (reserved.contains(name) || find(name) != null) {
      name = '$candidate-${suffix++}';
    }
    return name;
  }

  /// The secure-store key name backing [baseUrl]'s key:
  /// `FA_KEY_LOCALHOST_11434`, `FA_KEY_API_ACME_COM` (the store accepts
  /// `[A-Za-z0-9_]+` only). With [providerName] (a saved entry's name) the
  /// name is appended — `FA_KEY_API_KIMI_COM_WORK` — so several accounts on
  /// the same endpoint keep separate keys instead of overwriting one
  /// host-scoped entry.
  static String keyNameFor(String baseUrl, {String? providerName}) {
    final uri = Uri.tryParse(baseUrl);
    final sanitized = _sanitizeKeyHost(_hostWithPort(uri, baseUrl));
    final base = 'FA_KEY_${sanitized.isEmpty ? 'CUSTOM' : sanitized}';
    final name = providerName == null ? null : _sanitizeKeyHost(providerName);
    // A provider named after its host (the default derived name) must not
    // double the suffix: FA_KEY_API_AIIN_BY, not FA_KEY_API_AIIN_BY_API_AIIN_BY.
    return name == null || name.isEmpty || name == sanitized
        ? base
        : '${base}_$name';
  }

  /// The secure-store/env key name backing a connected Copilot account:
  /// `FA_KEY_COPILOT_<SANITIZED_ENTRY_NAME>` (goal/copilot_provider.md).
  /// Scoped to the ENTRY (not the host) so several accounts — possibly on
  /// different plans, hence different hosts — keep separate key slots, and
  /// so CI can supply `FA_KEY_COPILOT_<NAME>` (+ `_2`…) without a store.
  static String copilotEntryKeyName(String entryName) =>
      'FA_KEY_COPILOT_${_sanitizeKeyHost(entryName)}';

  /// The host part of [uri] (falling back to [baseUrl]), with a non-default
  /// port appended.
  static String _hostWithPort(Uri? uri, String baseUrl) {
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) host = 'custom';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    if (port != null && port != defaultPort) host = '${host}_$port';
    return host;
  }

  /// Uppercased, non-alphanumerics collapsed to `_`, edge underscores
  /// trimmed.
  static String _sanitizeKeyHost(String value) {
    return value
        .toUpperCase()
        .replaceAll(RegExp('[^A-Z0-9]+'), '_')
        .replaceAll(RegExp('^_+|_+\$'), '');
  }
}
