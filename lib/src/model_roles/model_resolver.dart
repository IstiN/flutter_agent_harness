/// Runtime resolution for model roles: turns a [ModelRolesConfig] plus a
/// secrets snapshot into per-role [FallbackStreamFunction]s, and applies
/// roles to an [Agent].
///
/// This is the consumer surface of the model-roles feature:
///
/// - the agent gets a role per run via [applyToAgent] (hosts default to
///   `default`; the role decides model + stream for the run);
/// - compaction summarization resolves through `smol` via [resolveRole] when
///   that role is configured (cheap summaries), else the caller keeps its
///   legacy model;
/// - `/model` renders [describeRoles].
///
/// Chain entries whose API key is absent from the secrets snapshot are
/// skipped (omp ignores uncredentialed fallback targets) and reported in
/// [skippedEntries]; a role whose chain resolves to nothing throws the
/// degradable [UnusableRoleChainException] (gh-1570: never a plain boot
/// exit on a recoverable config).
library;

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../exceptions.dart';
import '../model.dart';
import '../secrets/secrets_store.dart';
import '../cli/custom_providers.dart'
    show CustomProviderEntry, CustomProviderRegistry, sameEndpoint;
import 'fallback_stream.dart';
import 'key_rotation.dart';
import 'roles_config.dart';
import 'provider_catalog.dart';
import '../providers/silent_stream_policy.dart';
import '../providers/transient_retry_stream.dart' show transientRetryNotice;

/// gh-760 (review): the role's chain has NO usable entry. The boot
/// boundary degrades THIS shape to the legacy single-model path with a
/// loud, named warning — never process exit. gh-1570 (incident
/// 2026-10-12) generalized the contract: a recoverable aggregate (every
/// entry missing its key — set it with `/key set`, reboot, repaired) is
/// the same degrade, because hard-exiting the binary locks the user out
/// of the tool exactly when they need it to repair the config. Known
/// subclasses mark WHY the chain died; the boot treats them identically.
final class UnusableRoleChainException extends ConfigException {
  /// Creates the exception with the joined skip reasons.
  const UnusableRoleChainException(super.message);
}

/// gh-760 (review): the role's chain has NO usable entry AND the skip
/// reasons include unknown providers — a config written by a newer
/// app/CLI version. A typed subtype of the degradable
/// [UnusableRoleChainException] so callers can still distinguish
/// version skew from a current-version recoverable gap; the boot
/// degrades both identically (the drop is whole-resolver BY DESIGN —
/// gh-760 review: the per-turn main-model path re-enters chainFor, so a
/// half-alive resolver would move the failure to mid-session).
final class UnknownProviderRoleException extends UnusableRoleChainException {
  /// Creates the exception with the joined skip reasons.
  const UnknownProviderRoleException(super.message);
}

/// Builds per-role fallback chains from configuration and secrets.
final class ModelRolesResolver {
  /// Creates a resolver over [config] and a snapshot of [secrets]
  /// (name → value). [cwd]/[homeDir] feed path-override matching;
  /// [now]/[jitterFraction]/[sleeper] are injectable for deterministic
  /// tests and forwarded to every chain wrapper. [streamFactory] builds the
  /// per-key provider adapter (defaults to [providerStreamFunction]; tests
  /// inject fakes).
  ModelRolesResolver({
    required this.config,
    required Map<String, String> secrets,
    this.customProviders = const [],
    this.cwd,
    this.homeDir,
    this.onNotice,
    DateTime Function()? now,
    this.jitterFraction,
    this.sleeper,
    StreamFunction Function(String kind, String apiKey)? streamFactory,
  }) : _secrets = Map.unmodifiable(secrets),
       _now = now ?? DateTime.now,
       _streamFactory = streamFactory ?? providerStreamFunction;

  /// Builds a resolver from a [SecretsStore] (reads the bulk snapshot once).
  static Future<ModelRolesResolver> fromSecretsStore(
    ModelRolesConfig config,
    SecretsStore store, {
    String? cwd,
    String? homeDir,
    void Function(FallbackNotice notice)? onNotice,
    DateTime Function()? now,
    double Function()? jitterFraction,
    Future<bool> Function(Duration delay, CancelToken? cancelToken)? sleeper,
    StreamFunction Function(String kind, String apiKey)? streamFactory,
  }) async {
    return ModelRolesResolver(
      config: config,
      secrets: await store.readAll(),
      cwd: cwd,
      homeDir: homeDir,
      onNotice: onNotice,
      now: now,
      jitterFraction: jitterFraction,
      sleeper: sleeper,
      streamFactory: streamFactory,
    );
  }

  /// The active configuration (replaced by [setDefaultChain]).
  ModelRolesConfig config;

  /// The saved custom providers (the `customProviders:` config section) —
  /// the registry leg of chain-name resolution (issue #1552): a chain
  /// entry naming one of these entries (`provider: aiai`) resolves through
  /// the entry's apiType spec, with the entry's `baseUrl`/`keyName` as
  /// defaults where the ref omits them. Empty (default) = the legacy
  /// catalog-only surface; nothing existing changes shape.
  final List<CustomProviderEntry> customProviders;

  /// The working directory used for path-override matching.
  final String? cwd;

  /// Home directory for `~` override patterns.
  final String? homeDir;

  /// Receives every chain wrapper's [FallbackNotice]. Mutable so hosts can
  /// attach rendering after construction; wrappers forward to the current
  /// value.
  void Function(FallbackNotice notice)? onNotice;

  /// Cache-affinity session id bound into every chain entry's provider
  /// stream (resolved lazily per call, so a host that learns the session id
  /// after construction — the CLI/app create sessions lazily — still gets
  /// prompt-cache affinity). Ignored for adapters without cache routing.
  String? Function()? sessionId;

  /// Jitter source forwarded to chain wrappers (tests inject determinism).
  final double Function()? jitterFraction;

  /// Sleep implementation forwarded to chain wrappers (tests inject fakes).
  final Future<bool> Function(Duration delay, CancelToken? cancelToken)?
  sleeper;

  Map<String, String> _secrets;
  final DateTime Function() _now;
  final StreamFunction Function(String kind, String apiKey) _streamFactory;
  final _rings = <String, ApiKeyRing>{};
  final _wrappers = <String, FallbackStreamFunction>{};

  /// Registers an additional secret at runtime — a key typed into a
  /// provider wizard while the session runs. The constructor's snapshot is
  /// immutable by design, so this swaps in an extended copy and drops the
  /// cached key rings and chain wrappers: the next run re-resolves with the
  /// new secret available.
  void addSecret(String name, String value) {
    _secrets = Map.unmodifiable({..._secrets, name: value});
    _rings.clear();
    _wrappers.clear();
  }

  /// Chain entries skipped during the last [chainFor] per role, as
  /// `provider/modelId (reason)` — resolution must not degrade silently.
  final skippedEntries = <String, List<String>>{};

  /// Resolves [role]'s chain for [cwd] and builds the entries (models from
  /// the provider catalog, key rings from the secrets snapshot).
  ///
  /// Returns `null` when neither [role] nor the inherited `default` role is
  /// configured (the caller keeps its legacy single-model wiring).
  List<ChainEntry>? chainFor(String role) {
    final refs = config.chainFor(role, cwd: cwd, homeDir: homeDir);
    if (refs == null) return null;
    final skipped = skippedEntries[role] = <String>[];
    final entries = <ChainEntry>[];
    // Typed version-skew marker (gh-760 review): classification NEVER
    // substring-matches the human-readable skip reasons — those embed
    // user-controlled text (provider/modelId labels).
    var sawUnknownProvider = false;
    for (final ref in refs) {
      final entry = _buildEntry(
        ref,
        skipped,
        role: role,
        onUnknownProvider: () => sawUnknownProvider = true,
      );
      if (entry != null) entries.add(entry);
    }
    if (entries.isEmpty) {
      final message =
          'role "$role" has no usable chain entry: ${skipped.join('; ')}';
      // gh-760: degrade, never brick. Unknown providers (a config written
      // by a newer app/CLI) throw the dedicated version-skew subtype.
      // gh-1570 (incident 2026-10-12): a chain of KNOWN providers merely
      // missing keys degrades TOO — the same degradable base, never a
      // plain ConfigException: the boot must not process-exit on a
      // condition a `/key set` repairs (the old pre-#760 loud-failure
      // stance locked the user out of the repair tool itself).
      throw sawUnknownProvider
          ? UnknownProviderRoleException(message)
          : UnusableRoleChainException(message);
    }
    return entries;
  }

  ChainEntry? _buildEntry(
    ModelRef ref,
    List<String> skipped, {
    required String role,
    required void Function() onUnknownProvider,
  }) {
    // gh-760 (review): resolve by catalog name AND adapter kind — a roles
    // entry written as a kind (`chatgpt-codex`, exactly what the app
    // writes) is KNOWN to this version and must not be skipped as unknown.
    // honorBuildFilter: roles are a user-facing surface — the filter the
    // old name-only + kind-loop pair applied, now in the one seam.
    var spec = resolveCliProviderSpec(ref.provider, honorBuildFilter: true);
    if (spec == null) {
      // Issue #1552: the catalog missed — a hand-written config may name
      // a `customProviders:` entry (`provider: aiai`). The registry leg
      // (_registryLeg) resolves through the entry: its apiType's catalog
      // spec, with the entry's baseUrl/keyName as defaults where the ref
      // omits them (explicit ref fields always win). The reserved-name
      // rule (isReservedCustomProviderName) bars registry entries from
      // catalog names, so this leg only ever answers what the catalog
      // missed — the two namespaces never shadow.
      final viaRegistry = _registryLeg(
        ref,
        skipped,
        onUnknownProvider: onUnknownProvider,
      );
      if (viaRegistry != null) {
        (ref, spec) = viaRegistry;
      }
    }
    if (spec == null) {
      // gh-760: degrade, never brick. An entry whose provider no version
      // knows (a config written by a newer app/CLI) skips like a
      // missing-key entry — reported in skippedEntries, never thrown —
      // so the remaining known entries carry the role.
      skipped.add('${ref.label} (unknown provider: ${ref.provider})');
      onUnknownProvider();
      return null;
    }
    // Non-null alias: the registry leg reassigns `spec` above and
    // `buildRouted` below captures it — flow analysis never promotes a
    // captured local that is assigned more than once, so the closure must
    // read a final.
    final resolvedSpec = spec;
    // gh-1570 (AC8): a keyless ref needs NO credential — a localhost
    // bench endpoint or an unauthenticated gateway. The check PREEMPTS
    // key discovery: no env name is probed, and the stream factory
    // receives the EMPTY key, byte-parity with the non-roles keyless
    // boot (a saved config's stray key never leaks onto the pin).
    final ApiKeyRing ring;
    if (ref.keyless) {
      ring = ApiKeyRing(
        baseName: '',
        credentials: const [ApiKeyCredential('', '')],
      );
    } else {
      final keyBase = _keyBaseName(ref, resolvedSpec);
      if (keyBase == null) {
        skipped.add(
          '${ref.label} (missing API key: ${_missingKeyHint(ref, resolvedSpec)})',
        );
        return null;
      }
      ring = _rings.putIfAbsent(
        keyBase,
        () => ApiKeyRing.fromSecrets(_secrets, keyBase, now: _now)!,
      );
    }
    // gh-1395 review round 1: ONE policy per chain entry (session-scoped).
    // streamForKey is invoked per fallback ATTEMPT; building the policy
    // inside it would mint a fresh ledger every attempt and AC4/E3's
    // cross-call escalation (5→10→20 s, rotation, takeover) could never
    // happen. Memoized here: the ledger survives across attempts AND
    // calls; `currentKey` re-binds on every streamForKey so the fallback's
    // own credential choice (affinity/rate-limit rotation) is honored,
    // and [buildRouted] re-reads it per attempt so a rotation rebinds.
    SilentStreamPolicy? entryPolicy;
    var currentKey = ring.currentCredential.value;

    StreamFunction buildRouted() {
      final inner = _streamFactory(resolvedSpec.kind, currentKey);
      return (model, context, {cancelToken}) {
        // An explicit per-call override (the compaction bypass) wins
        // over the resolver's bound session id.
        if (StreamCacheRouting.current != null) {
          return inner(model, context, cancelToken: cancelToken);
        }
        return StreamCacheRouting.runWith(
          () => inner(model, context, cancelToken: cancelToken),
          // Read the mutable field lazily: hosts learn the session id
          // after the resolver (and its chains) were built.
          sessionId: sessionId?.call(),
        );
      };
    }

    return ChainEntry(
      // Build from the RESOLVED spec's name: a kind-named ref
      // (`chatgpt-codex`) is not itself a catalog key.
      model: buildCatalogModel(
        resolvedSpec.name,
        ref.modelId,
        baseUrl: ref.baseUrl,
        contextWindow: ref.contextWindow,
        maxTokens: ref.maxTokens,
        input: ref.input,
        thinkingLevel: ref.thinkingLevel,
        authHeader: ref.authHeader,
        // Request-scoped watchdog windows (issue #1554): the chain
        // entry's own fields are the TOP precedence layer, riding the
        // model — the streams of this role (and only this role) watch
        // under its windows even when another entry shares the endpoint.
        connectTimeout: ref.connectTimeout,
        streamIdleTimeout: ref.streamIdleTimeout,
        timeoutScopeLabel:
            ref.connectTimeout == null && ref.streamIdleTimeout == null
            ? null
            : 'role $role override',
      ),
      keyRing: ring,
      streamForKey: (apiKey) {
        currentKey = apiKey;
        final policy = entryPolicy ??= SilentStreamPolicy(
          innerBuilder: buildRouted,
          hooks: SilentStreamPolicyHooks(
            rotateKey: () {
              final rotated = rotateRingPast(ring, currentKey);
              if (rotated) {
                // rotate() advanced the ring's affinity — the new
                // current credential is the one the next attempt uses.
                currentKey = ring.currentCredential.value;
              }
              return rotated;
            },
            buildTakeover: role == smolModelRole ? null : _smolTakeoverStream,
            onNotice: (note) =>
                transientRetryNotice?.call(0, 1, Duration.zero, note),
          ),
          sleeper: sleeper,
        );
        // gh-1395 (AC4): every chain entry's stream rides the
        // SilentStreamPolicy — a PRE-commit idle stall gets the bounded,
        // escalating ladder (backoff 5→60s, key rotation on the ring after
        // the 2nd stall of the run, smol-role takeover attempt after the
        // 3rd) instead of a blind same-upstream replay (bench recovery
        // 1/13). Non-stall classes pass through untouched: transport
        // failures still replay in the transient ladder, rate limits still
        // rotate in the roles ladder, and the policy never replays
        // post-commit content (#964).
        return policy.call;
      },
    );
  }

  /// Rotates [ring] past the credential whose VALUE is [currentValue] —
  /// translated to its secrets-store NAME first, because `ApiKeyRing
  /// .rotate` matches by name and a raw value never matches (review round
  /// 1). `false` for a single-key ring (E5: the policy logs the skip and
  /// retries the same credential) or when every key is benched.
  static bool rotateRingPast(ApiKeyRing ring, String currentValue) {
    if (ring.length <= 1) return false;
    final current = ring.credentialByValue(currentValue);
    final next = ring.rotate(current?.name ?? ring.currentCredential.name);
    return next != null;
  }

  /// The registry LEG of chain-name resolution (issue #1552): the catalog
  /// missed [ref]'s provider, so try the saved `customProviders:` entries.
  /// A matched entry resolves through its apiType's catalog spec (same
  /// honorBuildFilter rule as every user-facing roles surface), with the
  /// entry's `baseUrl`/`keyName` as defaults where the ref omits them
  /// (explicit ref fields always win). Returns the defaulted ref paired
  /// with its spec, or null when this leg has no answer:
  /// - no entry matches → the caller reports the generic unknown-provider
  ///   skip (a name known to NEITHER namespace — gh-760);
  /// - the matched entry's apiType is unknown to this version (a saved
  ///   entry written by a newer CLI) → reported HERE as an unknown
  ///   adapter dialect — the registry entry IS known, only its dialect
  ///   isn't, so "unknown provider" would send the user hunting an entry
  ///   spelling that is fine.
  /// Both null paths keep the gh-760 skip+degrade contract (version skew,
  /// recoverable), classified via [onUnknownProvider] where the entry
  /// itself was recognized.
  (ModelRef, ProviderSpec)? _registryLeg(
    ModelRef ref,
    List<String> skipped, {
    required void Function() onUnknownProvider,
  }) {
    final entry = _findCustomProvider(ref.provider);
    if (entry == null) return null;
    final spec = resolveCliProviderSpec(entry.apiType, honorBuildFilter: true);
    if (spec != null) return (_throughCustomEntry(ref, entry), spec);
    skipped.add('${ref.label} (unknown adapter dialect: ${entry.apiType})');
    onUnknownProvider();
    return null;
  }

  /// The saved custom entry named by a chain ref (case-insensitive), or
  /// null — the registry leg of the resolver's name resolution (issue
  /// #1552). No alias canonicalization here: chain refs are hand-written
  /// names, and the registry's own load merge already folded alias twins.
  CustomProviderEntry? _findCustomProvider(String name) {
    final lower = name.trim().toLowerCase();
    for (final entry in customProviders) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    return null;
  }

  /// Defaults [ref]'s pin fields from the custom entry the ref named
  /// (issue #1552): the entry supplies `baseUrl` and `keyName` where the
  /// ref omits them; explicit ref fields always win. Every other field
  /// (model, window/token/modality/thinking/auth-header/tuning overrides)
  /// is the ref's own, exactly as for a kind+baseUrl entry.
  ModelRef _throughCustomEntry(ModelRef ref, CustomProviderEntry entry) {
    if (ref.baseUrl != null && ref.apiKeyName != null) return ref;
    return ModelRef(
      provider: ref.provider,
      modelId: ref.modelId,
      apiKeyName: ref.apiKeyName ?? entry.keyName,
      baseUrl: ref.baseUrl ?? entry.baseUrl,
      contextWindow: ref.contextWindow,
      maxTokens: ref.maxTokens,
      input: ref.input,
      thinkingLevel: ref.thinkingLevel,
      authHeader: ref.authHeader,
      connectTimeout: ref.connectTimeout,
      streamIdleTimeout: ref.streamIdleTimeout,
      // gh-1570 (AC8): a keyless ref routed through a custom entry keeps
      // its keyless flag — the rebuild must not reset it to false and
      // send the resolver probing for a credential the endpoint never
      // takes.
      keyless: ref.keyless,
    );
  }

  /// The key base name for [ref]: its explicit `apiKeyName`, else — for a
  /// chain entry pinned to a CUSTOM endpoint — the endpoint-scoped
  /// `FA_KEY_<HOST>` slot (the same source a manual provider switch
  /// resolves; gh-1000 AC5), else the first of the provider's env names
  /// present in the secrets snapshot. `null` when no candidate resolves
  /// to a configured key.
  String? _keyBaseName(ModelRef ref, ProviderSpec spec) {
    final explicit = ref.apiKeyName;
    if (explicit != null) {
      if (collectKeyStack(_secrets, explicit).isNotEmpty) return explicit;
      // gh-1570 incident REG: the pin NAMES a slot, but a derivation
      // change across versions can leave the key under the previous
      // release's name (the 1.0.556 → 1.0.564 lockout: the record-scoped
      // pin went unpopulated while the key sat on the host-scoped slot).
      // The pin stays first choice; an empty pin falls back to the
      // endpoint's own slot family (canonical + host-scoped) before the
      // ref is declared key-missing.
      return _firstConfigured(ref, spec) ?? _missingPinFallback(ref);
    }
    return _firstConfigured(ref, spec);
  }

  /// The endpoint-scoped candidate slots (gh-1570 cross-version set,
  /// canonical first) probed when a ref's explicit pin is EMPTY: the pin's
  /// own endpoint family, regardless of whether the endpoint is the
  /// catalog default (the incident pin sat on kimi's default URL).
  String? _missingPinFallback(ModelRef ref) {
    final baseUrl = ref.baseUrl;
    if (baseUrl == null) return null;
    for (final scoped in CustomProviderRegistry.keySlotCandidates(baseUrl)) {
      if (collectKeyStack(_secrets, scoped).isNotEmpty) return scoped;
    }
    return null;
  }

  /// The pre-gh-1570 resolution order for an unpinned ref: the
  /// endpoint-scoped slots (cross-version set), then the provider's env
  /// names — the first base with a configured key wins.
  String? _firstConfigured(ModelRef ref, ProviderSpec spec) {
    for (final scoped in _endpointScopedKeyNames(ref, spec)) {
      if (collectKeyStack(_secrets, scoped).isNotEmpty) return scoped;
    }
    for (final candidate in spec.apiKeyEnvNames) {
      if (collectKeyStack(_secrets, candidate).isNotEmpty) return candidate;
    }
    return null;
  }

  /// The endpoint-scoped `FA_KEY_<HOST>` slot names for a chain entry
  /// pinned to a non-default endpoint, canonical first — else empty. The
  /// snapshot carries every cross-spelling slot's value when the host
  /// collected them (the startup snapshot preloads the same set —
  /// gh-1000, gh-1570).
  List<String> _endpointScopedKeyNames(ModelRef ref, ProviderSpec spec) {
    final baseUrl = ref.baseUrl;
    // Trailing-slash-normalized (the shared sameEndpoint rule): a default
    // endpoint saved with a trailing slash must not mint a bogus scoped
    // slot — one endpoint-equality rule with key_status (round-3 review).
    if (baseUrl == null || sameEndpoint(baseUrl, spec.defaultBaseUrl)) {
      return const [];
    }
    return CustomProviderRegistry.keySlotCandidates(baseUrl);
  }

  /// The canonical endpoint-scoped slot for [ref] — the name the
  /// missing-key hint tells the user to set (the fix-it target), not the
  /// whole fallback set.
  String? _endpointScopedKeyName(ModelRef ref, ProviderSpec spec) =>
      _endpointScopedKeyNames(ref, spec).firstOrNull;

  /// The missing-key hint for [ref]'s skip reason: an explicitly pinned
  /// `apiKeyName` names THAT slot (the only name that would resolve it —
  /// the endpoint-scoped default would be wrong-slot guidance, gh-1000
  /// AC2), a custom endpoint names its `/key set` fix (the catalog env
  /// name would point at the DEFAULT endpoint — the wrong slot, gh-1000
  /// AC2/AC5), a default endpoint names its env var.
  String _missingKeyHint(ModelRef ref, ProviderSpec spec) {
    final explicit = ref.apiKeyName;
    if (explicit != null) {
      return '/key set $explicit <value>';
    }
    final scopedName = _endpointScopedKeyName(ref, spec);
    if (scopedName != null) {
      return '/key set $scopedName <value>';
    }
    return 'set ${spec.apiKeyEnvNames.first}';
  }

  /// The cached [FallbackStreamFunction] for [role] (entry cooldowns and
  /// chain position persist across runs — session state).
  FallbackStreamFunction streamForRole(String role) {
    return _wrappers.putIfAbsent(role, () {
      final entries = chainFor(role);
      if (entries == null) {
        throw ConfigException('role "$role" is not configured');
      }
      return FallbackStreamFunction(
        entries: entries,
        policy: config.retry,
        onNotice: (notice) => onNotice?.call(notice),
        now: _now,
        jitterFraction: jitterFraction,
        sleeper: sleeper,
      );
    });
  }

  /// The smol-role takeover stream, or `null` when smol is not configured
  /// (the policy logs the skip; the stall error stands). Runs at ESCALATION
  /// time (the 3rd stall), never at entry build. Split out of
  /// [_buildEntry]'s takeover closure (CRAP ratchet): the catch-clause
  /// line is never credited by the VM's coverage instrumentation even when
  /// the handler runs — at CC 12 that read as one permanently-uncovered
  /// line → CRAP 12.0008 > the 12.0 ratchet, unfixable by tests in place.
  StreamFunction? _smolTakeoverStream() {
    try {
      final smolWrapper = streamForRole(smolModelRole);
      final smolModel = smolWrapper.currentModel;
      return (model, context, {cancelToken}) =>
          smolWrapper.call(smolModel, context, cancelToken: cancelToken);
    } on ConfigException {
      return null; // smol not configured (logged by the policy)
    }
  }

  /// Resolves [role] to its current model and stream function, or `null`
  /// when the role (and the inherited `default`) is unconfigured.
  ({Model model, StreamFunction stream})? resolveRole(String role) {
    if (config.chainFor(role, cwd: cwd, homeDir: homeDir) == null) {
      return null;
    }
    final wrapper = streamForRole(role);
    return (model: wrapper.currentModel, stream: wrapper.call);
  }

  /// Points [agent] at [role]'s model and fallback stream for subsequent
  /// runs (the agent's role for a run; hosts use `default` for user turns).
  void applyToAgent(Agent agent, {String role = defaultModelRole}) {
    final wrapper = streamForRole(role);
    agent.streamFunction = wrapper.call;
    agent.state.model = wrapper.currentModel;
  }

  /// Replaces the `default` role's chain (runtime `/model <id>` switch);
  /// the new chain takes effect on the next run.
  void setDefaultChain(List<ModelRef> chain) {
    setRoleChain(defaultModelRole, chain);
  }

  /// Replaces [role]'s chain (the settings-hub agent-models flow); the new
  /// chain takes effect on the next run.
  void setRoleChain(String role, List<ModelRef> chain) {
    if (chain.isEmpty) {
      throw ArgumentError.value(
        chain,
        'chain',
        'a role needs at least one chain entry',
      );
    }
    config = ModelRolesConfig(
      roles: {...config.roles, role: chain},
      pathOverrides: config.pathOverrides,
      retry: config.retry,
    );
    _wrappers.remove(role);
  }

  /// Replaces the retry policy (the settings-hub resilience flow, issue
  /// #393). Every role's cached wrapper captured the old policy at
  /// construction, so ALL of them are rebuilt — the new knobs govern the
  /// next run's retry chain; a run already streaming keeps the old one.
  void setRetryPolicy(ModelRolesRetryPolicy policy) {
    config = ModelRolesConfig(
      roles: config.roles,
      pathOverrides: config.pathOverrides,
      retry: policy,
    );
    _wrappers.clear();
  }

  /// Drops every cached chain wrapper so the next run rebuilds its models
  /// through the CURRENT capability override layer (gh-1426: the settings
  /// flow calls this after a `models.overrides` write — a run already
  /// streaming keeps its resolved caps, the next run picks the edit up).
  void refreshCapabilities() {
    _wrappers.clear();
  }

  /// "use the main model" escape of the settings-hub agent-models flow).
  void clearRoleChain(String role) {
    if (role == defaultModelRole) {
      throw ArgumentError.value(role, 'role', 'the default role is required');
    }
    if (!config.roles.containsKey(role)) return;
    final roles = {...config.roles}..remove(role);
    config = ModelRolesConfig(
      roles: roles,
      pathOverrides: config.pathOverrides,
      retry: config.retry,
    );
    _wrappers.remove(role);
  }

  /// Renders the roles overview for `/model`: each configured role with its
  /// chain, the active entry marked (`*`), cooling-down entries annotated,
  /// and skipped entries listed.
  String describeRoles() {
    final buffer = StringBuffer();
    for (final role in modelRoleIds) {
      final chain = config.chainFor(role, cwd: cwd, homeDir: homeDir);
      if (chain == null) continue;
      _describeRole(buffer, role, chain);
    }
    return buffer.toString().trimRight();
  }

  /// Renders one role block: the header line (with the inherit-default
  /// annotation), its chain entries, and its skipped entries.
  void _describeRole(StringBuffer buffer, String role, List<ModelRef> chain) {
    final wrapper = _wrappers[role];
    final inherited =
        role != defaultModelRole && !config.roles.containsKey(role);
    buffer.write('$role${inherited ? ' (inherits default)' : ''}:');
    _describeChainEntries(buffer, chain, wrapper);
    final skipped = skippedEntries[role];
    if (skipped != null && skipped.isNotEmpty) {
      buffer.write('\n  skipped: ${skipped.join('; ')}');
    }
    buffer.write('\n');
  }

  /// Renders [chain]'s entries, marking the wrapper's active entry (`*`)
  /// and annotating cooling-down entries.
  void _describeChainEntries(
    StringBuffer buffer,
    List<ModelRef> chain,
    FallbackStreamFunction? wrapper,
  ) {
    for (var i = 0; i < chain.length; i++) {
      final active = wrapper != null && wrapper.activeIndex == i;
      final cooldown = wrapper?.cooldownRemaining(i);
      buffer.write(
        '\n  ${active ? '*' : ' '} ${chain[i].label}'
        '${cooldown == null ? '' : ' (cooldown ${cooldown.inSeconds}s)'}',
      );
    }
  }
}
