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
/// [skippedEntries]; a role whose chain resolves to nothing throws
/// [ConfigException].
library;

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../exceptions.dart';
import '../model.dart';
import '../secrets/secrets_store.dart';
import 'fallback_stream.dart';
import 'key_rotation.dart';
import 'roles_config.dart';
import 'provider_catalog.dart';

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

  /// The working directory used for path-override matching.
  final String? cwd;

  /// Home directory for `~` override patterns.
  final String? homeDir;

  /// Receives every chain wrapper's [FallbackNotice]. Mutable so hosts can
  /// attach rendering after construction; wrappers forward to the current
  /// value.
  void Function(FallbackNotice notice)? onNotice;

  /// Jitter source forwarded to chain wrappers (tests inject determinism).
  final double Function()? jitterFraction;

  /// Sleep implementation forwarded to chain wrappers (tests inject fakes).
  final Future<bool> Function(Duration delay, CancelToken? cancelToken)?
  sleeper;

  final Map<String, String> _secrets;
  final DateTime Function() _now;
  final StreamFunction Function(String kind, String apiKey) _streamFactory;
  final _rings = <String, ApiKeyRing>{};
  final _wrappers = <String, FallbackStreamFunction>{};

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
    for (final ref in refs) {
      final entry = _buildEntry(ref, skipped);
      if (entry != null) entries.add(entry);
    }
    if (entries.isEmpty) {
      throw ConfigException(
        'role "$role" has no usable chain entry: ${skipped.join('; ')}',
      );
    }
    return entries;
  }

  ChainEntry? _buildEntry(ModelRef ref, List<String> skipped) {
    final spec = catalogProvider(ref.provider);
    if (spec == null) {
      throw ConfigException(
        'unknown provider "${ref.provider}" — supported providers: '
        '${providerCatalog.keys.join(', ')}',
      );
    }
    final keyBase = _keyBaseName(ref, spec);
    if (keyBase == null) {
      skipped.add(
        '${ref.label} (missing API key: set ${spec.apiKeyEnvNames.first})',
      );
      return null;
    }
    final ring = _rings.putIfAbsent(
      keyBase,
      () => ApiKeyRing.fromSecrets(_secrets, keyBase, now: _now)!,
    );
    return ChainEntry(
      model: buildCatalogModel(
        ref.provider,
        ref.modelId,
        baseUrl: ref.baseUrl,
        contextWindow: ref.contextWindow,
        maxTokens: ref.maxTokens,
      ),
      keyRing: ring,
      streamForKey: (apiKey) => _streamFactory(spec.kind, apiKey),
    );
  }

  /// The key base name for [ref]: its explicit `apiKeyName`, else the first
  /// of the provider's env names present in the secrets snapshot. `null`
  /// when no candidate resolves to a configured key.
  String? _keyBaseName(ModelRef ref, ProviderSpec spec) {
    final explicit = ref.apiKeyName;
    if (explicit != null) {
      return collectKeyStack(_secrets, explicit).isEmpty ? null : explicit;
    }
    for (final candidate in spec.apiKeyEnvNames) {
      if (collectKeyStack(_secrets, candidate).isNotEmpty) return candidate;
    }
    return null;
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
    if (chain.isEmpty) {
      throw ArgumentError.value(
        chain,
        'chain',
        'the default role needs at least one chain entry',
      );
    }
    config = ModelRolesConfig(
      roles: {...config.roles, defaultModelRole: chain},
      pathOverrides: config.pathOverrides,
      retry: config.retry,
    );
    _wrappers.remove(defaultModelRole);
  }

  /// Renders the roles overview for `/model`: each configured role with its
  /// chain, the active entry marked (`*`), cooling-down entries annotated,
  /// and skipped entries listed.
  String describeRoles() {
    final buffer = StringBuffer();
    for (final role in modelRoleIds) {
      final chain = config.chainFor(role, cwd: cwd, homeDir: homeDir);
      if (chain == null) continue;
      final wrapper = _wrappers[role];
      final inherited =
          role != defaultModelRole && !config.roles.containsKey(role);
      buffer.write('$role${inherited ? ' (inherits default)' : ''}:');
      for (var i = 0; i < chain.length; i++) {
        final active = wrapper != null && wrapper.activeIndex == i;
        final cooldown = wrapper?.cooldownRemaining(i);
        buffer.write(
          '\n  ${active ? '*' : ' '} ${chain[i].label}'
          '${cooldown == null ? '' : ' (cooldown ${cooldown.inSeconds}s)'}',
        );
      }
      final skipped = skippedEntries[role];
      if (skipped != null && skipped.isNotEmpty) {
        buffer.write('\n  skipped: ${skipped.join('; ')}');
      }
      buffer.write('\n');
    }
    return buffer.toString().trimRight();
  }
}
