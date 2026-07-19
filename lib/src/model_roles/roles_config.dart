/// Intent-based model roles with ordered fallback chains and path-scoped
/// overrides — the configuration half of the model-roles feature.
///
/// Ported (reduced) from oh-my-pi `packages/coding-agent/src/config/
/// model-resolver.ts` and `model-roles.ts`. Deliberate reductions:
///
/// - Only the four card-mandated roles exist here: `default`, `smol`, `slow`,
///   `plan` (exact omp names). omp's `vision`/`designer`/`commit`/`tiny`/
///   `task`/`advisor` roles and its fuzzy catalog matching (`matchModel`,
///   thinking suffixes, `@upstream` routing) are not ported; our chains name
///   concrete `provider/modelId` entries resolved against the small
///   [provider catalog](provider_catalog.dart).
/// - Role inheritance is simplified to omp's
///   `shouldInheritDefaultBeforePriority` behavior: an unset non-default role
///   resolves through the `default` role's chain.
/// - Path-scoped overrides follow omp's scoped `enabledModels` semantics
///   (entry applies when the cwd is the configured path or a subdirectory),
///   extended with glob patterns (`*`, `**`) as the card requires.
///
/// Runtime resolution, key rotation, and the fallback stream live in the
/// sibling files of this directory; this file is pure configuration:
/// parsing, validation, serialization, and chain selection.
library;

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// The model roles supported by [ModelRolesConfig], in declaration order.
///
/// Exact omp role names (`default`, `smol`, `slow`, `plan`).
const modelRoleIds = ['default', 'smol', 'slow', 'plan'];

/// The role used for ordinary agent runs.
const defaultModelRole = 'default';

/// The role compaction summarization resolves through when configured.
const smolModelRole = 'smol';

/// One entry of a role's fallback chain: a concrete model plus an optional
/// API-key base-name override.
final class ModelRef {
  /// Creates a model reference.
  const ModelRef({
    required this.provider,
    required this.modelId,
    this.apiKeyName,
    this.baseUrl,
    this.contextWindow,
    this.maxTokens,
  });

  /// Parses the string shorthand `provider/modelId`.
  ///
  /// Throws [ConfigException] when [value] is not `<provider>/<modelId>`
  /// with both sides non-empty.
  factory ModelRef.parse(String value, {String? role}) {
    final slash = value.indexOf('/');
    if (slash <= 0 || slash == value.length - 1) {
      throw ConfigException(
        'invalid model reference "$value"${role == null ? '' : ' in role "$role"'}'
        ' — expected "provider/modelId"',
      );
    }
    return ModelRef(
      provider: value.substring(0, slash).trim(),
      modelId: value.substring(slash + 1).trim(),
    );
  }

  /// Parses one chain entry from yaml: either the string shorthand or a map
  /// with `provider`/`model` plus optional overrides.
  factory ModelRef.fromYaml(Object? node, {String? role}) {
    switch (node) {
      case String value:
        return ModelRef.parse(value, role: role);
      case YamlMap map:
        final provider = map['provider'];
        final model = map['model'];
        if (provider is! String || provider.trim().isEmpty) {
          throw ConfigException(
            'model chain entry${role == null ? '' : ' in role "$role"'} '
            'is missing a "provider" string',
          );
        }
        if (model is! String || model.trim().isEmpty) {
          throw ConfigException(
            'model chain entry${role == null ? '' : ' in role "$role"'} '
            'is missing a "model" string',
          );
        }
        return ModelRef(
          provider: provider.trim(),
          modelId: model.trim(),
          apiKeyName: _optionalString(map, 'apiKeyName', role),
          baseUrl: _optionalString(map, 'baseUrl', role),
          contextWindow: _optionalInt(map, 'contextWindow', role),
          maxTokens: _optionalInt(map, 'maxTokens', role),
        );
      default:
        throw ConfigException(
          'invalid model chain entry${role == null ? '' : ' in role "$role"'}: '
          'expected "provider/modelId" or a map, got ${node.runtimeType}',
        );
    }
  }

  static String? _optionalString(YamlMap map, String key, String? role) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw ConfigException(
        '"$key"${role == null ? '' : ' in role "$role"'} must be a '
        'non-empty string',
      );
    }
    return value.trim();
  }

  static int? _optionalInt(YamlMap map, String key, String? role) {
    final value = map[key];
    if (value == null) return null;
    if (value is! int || value <= 0) {
      throw ConfigException(
        '"$key"${role == null ? '' : ' in role "$role"'} must be a '
        'positive integer',
      );
    }
    return value;
  }

  /// Catalog provider name (e.g. `openrouter`, `openai`, `anthropic`,
  /// `google`); see `provider_catalog.dart`.
  final String provider;

  /// The model id sent to the provider (e.g. `anthropic/claude-sonnet-4`).
  final String modelId;

  /// Base name of the API key in the secrets store. Rotation stacks
  /// `[apiKeyName]` with `[apiKeyName]_2`, `[apiKeyName]_3`, ... When null,
  /// the provider's canonical env name is used.
  final String? apiKeyName;

  /// Provider base-URL override; the catalog default is used when null.
  final String? baseUrl;

  /// Context-window override (tokens); the catalog default is used when null.
  final int? contextWindow;

  /// Max-output-token override; the catalog default is used when null.
  final int? maxTokens;

  /// The `provider/modelId` display form.
  String get label => '$provider/$modelId';

  /// Serializes to the map form (round-trips with [ModelRef.fromYaml]).
  String toYaml() {
    final buffer = StringBuffer()
      ..write('provider: $provider\n')
      ..write('model: $modelId\n');
    if (apiKeyName != null) buffer.write('apiKeyName: $apiKeyName\n');
    if (baseUrl != null) buffer.write('baseUrl: $baseUrl\n');
    if (contextWindow != null) buffer.write('contextWindow: $contextWindow\n');
    if (maxTokens != null) buffer.write('maxTokens: $maxTokens\n');
    return buffer.toString();
  }
}

/// Knobs for the rate-limit retry/fallback engine, mirroring omp's
/// non-compaction retry policy (`retry.*` settings).
final class ModelRolesRetryPolicy {
  /// Creates a retry policy; all values have omp-shaped defaults.
  const ModelRolesRetryPolicy({
    this.retriesPerEntry = 2,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 8),
    this.maxWait = const Duration(minutes: 5),
    this.keyBackoff = const Duration(minutes: 1),
  });

  /// Parses the optional `retry:` yaml section.
  factory ModelRolesRetryPolicy.fromYaml(YamlMap map) {
    int? intValue(String key) {
      final value = map[key];
      if (value == null) return null;
      if (value is! int || value < 0) {
        throw ConfigException('"retry.$key" must be a non-negative integer');
      }
      return value;
    }

    Duration? ms(String key) {
      final value = intValue(key);
      return value == null ? null : Duration(milliseconds: value);
    }

    final retries = intValue('retriesPerEntry');
    return ModelRolesRetryPolicy(
      retriesPerEntry: retries ?? 2,
      baseDelay: ms('baseDelayMs') ?? const Duration(milliseconds: 500),
      maxBackoff: ms('maxBackoffMs') ?? const Duration(seconds: 8),
      maxWait: ms('maxWaitMs') ?? const Duration(minutes: 5),
      keyBackoff: ms('keyBackoffMs') ?? const Duration(minutes: 1),
    );
  }

  /// Same-model retries (with backoff) before the run falls to the next
  /// chain entry. Key rotations do not consume this budget (omp switches
  /// credentials for free before spending retries).
  final int retriesPerEntry;

  /// First backoff sleep between same-entry attempts (omp `retry.baseDelayMs`).
  final Duration baseDelay;

  /// Cap on the exponential same-entry backoff (omp caps at 8000 ms).
  final Duration maxBackoff;

  /// Give-up threshold: a required sleep longer than this fails over to the
  /// next chain entry instead of sleeping (omp `retry.maxDelayMs`).
  final Duration maxWait;

  /// How long a key (or chain entry) stays in backoff after a rate-limit
  /// failure that carried no `Retry-After` hint.
  final Duration keyBackoff;

  /// Backoff before same-entry attempt [attempt] (1-based): exponential from
  /// [baseDelay], capped at [maxBackoff], with 75–100% jitter (omp's
  /// Anthropic-style jitter so concurrent sessions do not retry in lockstep).
  Duration backoffFor(int attempt, double jitterFraction) {
    var ms = baseDelay.inMilliseconds * (1 << (attempt - 1).clamp(0, 20));
    if (ms > maxBackoff.inMilliseconds) ms = maxBackoff.inMilliseconds;
    final jitter = 0.75 + 0.25 * jitterFraction.clamp(0.0, 1.0);
    return Duration(milliseconds: (ms * jitter).round());
  }

  /// Serializes to yaml (round-trips with [ModelRolesRetryPolicy.fromYaml]).
  String toYaml() {
    return 'retriesPerEntry: $retriesPerEntry\n'
        'baseDelayMs: ${baseDelay.inMilliseconds}\n'
        'maxBackoffMs: ${maxBackoff.inMilliseconds}\n'
        'maxWaitMs: ${maxWait.inMilliseconds}\n'
        'keyBackoffMs: ${keyBackoff.inMilliseconds}\n';
  }
}

/// A path-scoped set of role chains, applied when the cwd matches [pattern].
final class PathRoleOverride {
  /// Creates an override for [pattern] with per-role chains.
  const PathRoleOverride({required this.pattern, required this.roles});

  /// Parses one `modelOverrides` yaml entry.
  factory PathRoleOverride.fromYaml(Object? node) {
    if (node is! YamlMap) {
      throw const ConfigException(
        'modelOverrides entries must be maps with "path" and "roles"',
      );
    }
    final path = node['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const ConfigException(
        'modelOverrides entries require a non-empty "path" string',
      );
    }
    return PathRoleOverride(
      pattern: path.trim(),
      roles: parseRoleChains(node['roles'], source: 'modelOverrides "$path"'),
    );
  }

  /// Absolute path, `~`-rooted path, or glob (`*` matches within a segment,
  /// `**` matches across segments).
  final String pattern;

  /// Role → chain pinned for matching directories.
  final Map<String, List<ModelRef>> roles;

  /// Serializes to yaml (round-trips with [PathRoleOverride.fromYaml]).
  String toYaml() {
    final buffer = StringBuffer()
      ..write('path: $pattern\n')
      ..write('roles:\n');
    buffer.write(_chainsToYaml(roles, indent: 2));
    return buffer.toString();
  }
}

/// Parses a `roles:` map (role name → chain). Shared by the top-level
/// section and [PathRoleOverride]; [source] labels errors.
Map<String, List<ModelRef>> parseRoleChains(Object? node, {String? source}) {
  String where(String role) =>
      source == null ? 'role "$role"' : '$source role "$role"';
  if (node is! YamlMap) {
    throw ConfigException(
      '${source ?? 'roles'} must be a map of role name to model chain',
    );
  }
  final roles = <String, List<ModelRef>>{};
  for (final entry in node.entries) {
    final role = entry.key;
    if (role is! String || !modelRoleIds.contains(role)) {
      throw ConfigException(
        'unknown model role "$role"${source == null ? '' : ' in $source'}'
        ' — supported roles: ${modelRoleIds.join(', ')}',
      );
    }
    final chainNode = entry.value;
    if (chainNode is! YamlList || chainNode.isEmpty) {
      throw ConfigException(
        '${where(role)} must be a non-empty list of model references',
      );
    }
    roles[role] = [
      for (final chainEntry in chainNode)
        ModelRef.fromYaml(chainEntry, role: role),
    ];
  }
  if (roles.isEmpty) {
    throw ConfigException('${source ?? 'roles'} declares no roles');
  }
  return roles;
}

String _chainsToYaml(Map<String, List<ModelRef>> roles, {int indent = 0}) {
  final pad = ' ' * indent;
  final buffer = StringBuffer();
  for (final role in modelRoleIds) {
    final chain = roles[role];
    if (chain == null) continue;
    buffer.write('$pad$role:\n');
    for (final ref in chain) {
      final lines = ref.toYaml().trimRight().split('\n');
      buffer.write('$pad  - ${lines.first}\n');
      for (final line in lines.skip(1)) {
        buffer.write('$pad    $line\n');
      }
    }
  }
  return buffer.toString();
}

/// Whether [pattern] matches the working directory [cwd].
///
/// Semantics (omp's scoped entries, extended with globs per the card):
///
/// - a `~` prefix expands against [homeDir] (pass it explicitly; this library
///   is pure Dart and never reads the environment itself);
/// - a pattern containing `*` is a glob: `*` matches any run of non-`/`
///   characters, `**` matches anything (including `/`);
/// - any other pattern is a path prefix: it matches the cwd itself and any
///   of its subdirectories.
///
/// Matching is lexical (no filesystem access); redundant trailing slashes
/// are stripped. The cwd should be absolute.
bool pathPatternMatches(String pattern, String cwd, {String? homeDir}) {
  var pat = pattern.trim();
  if (pat.startsWith('~')) {
    if (homeDir == null) return false;
    pat = pat.length == 1 ? homeDir : '$homeDir${pat.substring(1)}';
  }
  while (pat.length > 1 && pat.endsWith('/')) {
    pat = pat.substring(0, pat.length - 1);
  }
  var dir = cwd.trim();
  while (dir.length > 1 && dir.endsWith('/')) {
    dir = dir.substring(0, dir.length - 1);
  }
  if (pat.isEmpty || dir.isEmpty) return false;

  if (pat.contains('*')) {
    final regex = StringBuffer('^');
    for (var i = 0; i < pat.length; i++) {
      final char = pat[i];
      if (char == '*') {
        final doubleStar = i + 1 < pat.length && pat[i + 1] == '*';
        regex.write(doubleStar ? '.*' : '[^/]*');
        if (doubleStar) i++;
      } else {
        regex.write(RegExp.escape(char));
      }
    }
    regex.write(r'$');
    return RegExp(regex.toString()).hasMatch(dir);
  }

  return dir == pat || dir.startsWith('$pat/');
}

/// Model-role configuration: role → ordered fallback chains, path-scoped
/// overrides, and the retry policy.
final class ModelRolesConfig {
  /// Creates a config; [roles] maps role id to its ordered chain.
  ModelRolesConfig({
    required Map<String, List<ModelRef>> roles,
    this.pathOverrides = const [],
    this.retry = const ModelRolesRetryPolicy(),
  }) : roles = Map.unmodifiable({
         for (final entry in roles.entries)
           entry.key: List<ModelRef>.unmodifiable(entry.value),
       });

  /// Parses the `roles:` / `modelOverrides:` / `retry:` sections of the CLI
  /// config. Strict: any schema problem throws [ConfigException] (a corrupt
  /// roles section must surface, never silently reset to defaults).
  factory ModelRolesConfig.fromYaml(YamlMap map) {
    final rolesNode = map['roles'];
    if (rolesNode == null) {
      throw const ConfigException('no "roles" section in config');
    }
    final roles = parseRoleChains(rolesNode);

    final overridesNode = map['modelOverrides'];
    final overrides = <PathRoleOverride>[];
    if (overridesNode != null) {
      if (overridesNode is! YamlList) {
        throw const ConfigException('"modelOverrides" must be a list');
      }
      for (final entry in overridesNode) {
        overrides.add(PathRoleOverride.fromYaml(entry));
      }
    }

    final retryNode = map['retry'];
    if (retryNode != null && retryNode is! YamlMap) {
      throw const ConfigException('"retry" must be a map of retry settings');
    }
    final retry = retryNode == null
        ? const ModelRolesRetryPolicy()
        : ModelRolesRetryPolicy.fromYaml(retryNode);

    return ModelRolesConfig(
      roles: roles,
      pathOverrides: overrides,
      retry: retry,
    );
  }

  /// Role id → ordered fallback chain (first entry is primary).
  final Map<String, List<ModelRef>> roles;

  /// Path-scoped role chains, most-specific match wins.
  final List<PathRoleOverride> pathOverrides;

  /// Retry/fallback knobs.
  final ModelRolesRetryPolicy retry;

  /// Resolves [role]'s chain for the working directory [cwd].
  ///
  /// Resolution order (mirroring omp):
  ///
  /// 1. the longest matching [pathOverrides] pattern that pins [role];
  /// 2. the top-level [roles] chain for [role];
  /// 3. for non-default roles, the `default` role's chain (omp's
  ///    inherit-default-before-priority behavior);
  /// 4. `null` when nothing applies (the caller falls back to its legacy
  ///    single-model wiring).
  List<ModelRef>? chainFor(String role, {String? cwd, String? homeDir}) {
    if (!modelRoleIds.contains(role)) {
      throw ConfigException(
        'unknown model role "$role" — supported roles: '
        '${modelRoleIds.join(', ')}',
      );
    }
    if (cwd != null) {
      final matching =
          pathOverrides
              .where(
                (override) =>
                    override.roles.containsKey(role) &&
                    pathPatternMatches(override.pattern, cwd, homeDir: homeDir),
              )
              .toList()
            ..sort((a, b) => b.pattern.length.compareTo(a.pattern.length));
      if (matching.isNotEmpty) return matching.first.roles[role];
    }
    return roles[role] ??
        (role == defaultModelRole ? null : roles[defaultModelRole]);
  }

  /// Serializes to the `roles:` / `modelOverrides:` / `retry:` yaml sections
  /// (round-trips with [ModelRolesConfig.fromYaml]).
  String toYaml() {
    final buffer = StringBuffer()
      ..write('roles:\n')
      ..write(_chainsToYaml(roles, indent: 2));
    if (pathOverrides.isNotEmpty) {
      buffer.write('modelOverrides:\n');
      for (final override in pathOverrides) {
        final lines = override.toYaml().trimRight().split('\n');
        buffer.write('  - ${lines.first}\n');
        for (final line in lines.skip(1)) {
          buffer.write('    $line\n');
        }
      }
    }
    buffer
      ..write('retry:\n')
      ..write(
        retry
            .toYaml()
            .trimRight()
            .split('\n')
            .map((line) => '  $line\n')
            .join(),
      );
    return buffer.toString();
  }
}
