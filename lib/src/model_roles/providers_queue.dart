/// The provider queue configuration (issue #418): an ordered list of
/// `{provider_type, provider_config}` entries that replaces the MAIN model
/// resolution — set via the `FA_PROVIDERS_QUEUE` env var, the project
/// `.fah/config.yaml` `providersQueue:` section, or the user
/// `~/.fah/config.yaml` one.
///
/// This file is pure Dart (no IO, no dart:io): file reads behind the
/// `@path` env form and the process environment are injected by the host,
/// so every parser below is directly unit-testable and web-compilable
/// (REG-47). Scope precedence (env > project > user > legacy), boot
/// notices, dedup, and the editor's list operations live here too; the
/// runtime cursor/failover machinery lives in `queue_runtime.dart`.
///
/// Keys never ride in config blobs: an entry names its key by
/// `apiKeyEnv` (or inherits the saved custom provider's `keyName`) — a
/// literal `apiKey`/`api_key` value is a hard parse error (AC9).
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';

/// The default cooldown when a 429 carries no `Retry-After` (issue #418
/// open question 1: 60s proposed; one-line change if the owner prefers 30s).
const providerQueueDefaultCooldown = Duration(seconds: 60);

/// Cooldown clamp ceiling: a `Retry-After` beyond this (or a backoff
/// doubling past it) clamps here (UT-cooldown-borders).
const providerQueueMaxCooldown = Duration(hours: 24);

/// Consecutive-failure cooldown doubling cap: `base * 2^n` until this many
/// doublings, then the clamp holds (UT-backoff-doubling).
const providerQueueMaxBackoffDoublings = 6;

/// The adapter kinds a queue entry's `provider_type` may name — the same
/// dispatch [providerStreamFunction] accepts. Kept as a literal list so
/// parse errors can enumerate the candidates without importing the catalog
/// (and its transitive provider adapters) into every consumer.
const providerQueueKinds = [
  'openai-completions',
  'anthropic',
  'google',
  'dial',
  'minimax',
  'zai',
  'aiin',
  'chatgpt-codex',
  'copilot',
];

/// One ordered entry of the provider queue: an adapter kind, the model to
/// call on it, and the key indirection (`apiKeyEnv` — the env NAME, never
/// the value).
final class ProviderQueueEntry {
  /// Creates a validated entry. Throws [ArgumentError] on an unknown
  /// provider type or a blank model (the same strictness the parsers
  /// enforce, available to the editor).
  ProviderQueueEntry({
    required this.providerType,
    required this.model,
    this.baseUrl,
    this.apiKeyEnv,
    this.contextWindow,
    this.maxTokens,
    this.ref,
  }) {
    if (!providerQueueKinds.contains(providerType)) {
      throw ArgumentError.value(
        providerType,
        'providerType',
        'unknown provider_type — supported: ${providerQueueKinds.join(', ')}',
      );
    }
    if (model.trim().isEmpty) {
      throw ArgumentError.value(model, 'model', 'must be a non-empty string');
    }
  }

  /// The adapter dialect (`openai-completions`, `anthropic`, ...).
  final String providerType;

  /// The model id sent to the provider.
  final String model;

  /// Endpoint override; the kind's catalog default when null.
  final String? baseUrl;

  /// Env var NAME holding the API key. Null inherits the resolved custom
  /// provider's key name (ref entries) — keys never ride in the blob.
  final String? apiKeyEnv;

  /// Context-window override (tokens).
  final int? contextWindow;

  /// Max-output-token override (tokens).
  final int? maxTokens;

  /// only — the resolved fields are materialized at parse time).
  final String? ref;

  /// Parses one entry from a decoded JSON map (the env / `@file` form).
  /// Throws [ConfigException] with the 1-based [position] (entry index)
  /// in every message; unknown keys inside `provider_config` are tolerated
  /// as params and reported in [warnings].
  factory ProviderQueueEntry.fromJsonMap(
    Map<Object?, Object?> map, {
    required int position,
    List<String>? warnings,
  }) {
    final where = 'queue entry #$position';
    final type = map['provider_type'];
    if (type is! String || type.trim().isEmpty) {
      throw ConfigException(
        '$where: missing a "provider_type" string — '
        'supported: ${providerQueueKinds.join(', ')}',
      );
    }
    final providerType = type.trim();
    if (!providerQueueKinds.contains(providerType)) {
      throw ConfigException(
        '$where: unknown provider_type "$providerType" — '
        'supported: ${providerQueueKinds.join(', ')}',
      );
    }
    final config = map['provider_config'];
    if (config is! Map) {
      throw ConfigException(
        '$where: missing a "provider_config" object '
        '(needs at least {"model": "..."})',
      );
    }
    final model = config['model'];
    if (model is! String || model.trim().isEmpty) {
      throw ConfigException('$where: provider_config needs a "model" string');
    }
    for (final key in const ['apiKey', 'api_key', 'apiKeyValue']) {
      if (config[key] != null) {
        throw ConfigException(
          '$where: provider_config."$key" is not allowed — name the key '
          'with "apiKeyEnv" instead; key values never ride in config '
          'blobs',
        );
      }
    }
    final unknown = [
      for (final key in config.keys)
        if (key is String &&
            !const [
              'model',
              'baseUrl',
              'apiKeyEnv',
              'contextWindow',
              'maxTokens',
            ].contains(key))
          key,
    ];
    if (unknown.isNotEmpty && warnings != null) {
      warnings.add(
        '$where: unknown provider_config key(s) '
        '${unknown.map((k) => '"$k"').join(', ')} — carried as params',
      );
    }
    return ProviderQueueEntry(
      providerType: providerType,
      model: model.trim(),
      baseUrl: _optionalString(config, 'baseUrl', where),
      apiKeyEnv: _optionalString(config, 'apiKeyEnv', where),
      contextWindow: _optionalInt(config, 'contextWindow', where),
      maxTokens: _optionalInt(config, 'maxTokens', where),
    );
  }

  /// Parses a `{"ref": name}` entry: fields resolve through the saved
  /// custom providers; inline `provider_config` overrides win (UT-ref).
  /// [resolveRef] returns the referenced provider's fields, or null when
  /// dangling (the caller turns that into a boot error with candidates).
  static ProviderQueueEntry resolvedRef({
    required String name,
    required int position,
    required ({String kind, String? baseUrl, String model, String? keyName})?
    Function(String name)
    resolveRef,
    Map<Object?, Object?>? overrides,
  }) {
    final where = 'queue entry #$position';
    final resolved = resolveRef(name);
    if (resolved == null) {
      throw ConfigException(
        '$where: ref "$name" matches no customProviders entry',
      );
    }
    final model = overrides?['model'] as String?;
    final baseUrl = overrides?['baseUrl'] as String?;
    final apiKeyEnv = overrides?['apiKeyEnv'] as String?;
    final contextWindow = _optionalInt(
      overrides ?? const {},
      'contextWindow',
      where,
    );
    final maxTokens = _optionalInt(overrides ?? const {}, 'maxTokens', where);
    return ProviderQueueEntry(
      providerType: resolved.kind,
      model: (model != null && model.trim().isNotEmpty)
          ? model.trim()
          : resolved.model,
      baseUrl: (baseUrl != null && baseUrl.trim().isNotEmpty)
          ? baseUrl.trim()
          : resolved.baseUrl,
      apiKeyEnv: (apiKeyEnv != null && apiKeyEnv.trim().isNotEmpty)
          ? apiKeyEnv.trim()
          : resolved.keyName,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
      ref: name,
    );
  }

  /// Serializes to the JSON map shape (round-trips with [fromJsonMap]).
  Map<String, Object?> toJson() => {
    'provider_type': providerType,
    'provider_config': {
      'model': model,
      if (baseUrl != null) 'baseUrl': baseUrl,
      if (apiKeyEnv != null) 'apiKeyEnv': apiKeyEnv,
      if (contextWindow != null) 'contextWindow': contextWindow,
      if (maxTokens != null) 'maxTokens': maxTokens,
    },
  };

  /// The `provider/model` display label used by badges and switch events.
  String get label => '$providerType/$model';

  /// The dedup key: the full serialized form (E10 — same provider twice
  /// with different models stays two distinct entries).
  String get dedupKey => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is ProviderQueueEntry && other.dedupKey == dedupKey;

  @override
  int get hashCode => dedupKey.hashCode;
}

/// One parsed queue source: the entries plus whatever the parser wants the
/// boot log to say (unknown-key warnings, dedup notes).
final class ParsedProviderQueue {
  /// Creates the parse product.
  const ParsedProviderQueue({required this.entries, required this.warnings});

  /// The deduped (keep-first) entry list.
  final List<ProviderQueueEntry> entries;

  /// Non-fatal notes (unknown provider_config keys carried as params).
  final List<String> warnings;
}

/// Parses the queue entries from an already-decoded JSON/YAML list.
///
/// Strict per-entry validation (candidate-listing errors), keep-first
/// dedup with a warning, and `{"ref": ...}` resolution through
/// [resolveRef]. An empty list is an explicit error ("queue empty" —
/// UT-parse-empty-single): a queue must have at least one entry.
ParsedProviderQueue parseProviderQueueEntries(
  Object? node, {
  required String source,
  ({String kind, String? baseUrl, String model, String? keyName})? Function(
    String name,
  )?
  resolveRef,
}) {
  if (node is! List) {
    throw ConfigException(
      '$source: expected an array of '
      '{"provider_type", "provider_config"} entries, got ${_typeName(node)}',
    );
  }
  if (node.isEmpty) {
    throw ConfigException(
      '$source: the queue is empty — provide at least one entry or unset '
      'the queue to use the legacy provider/model configuration',
    );
  }
  final warnings = <String>[];
  final entries = <ProviderQueueEntry>[];
  final seen = <String>{};
  for (var i = 0; i < node.length; i++) {
    final item = node[i];
    if (item is! Map) {
      throw ConfigException(
        '$source: queue entry #${i + 1} must be an object, '
        'got ${_typeName(item)}',
      );
    }
    final ProviderQueueEntry entry;
    if (item['ref'] is String) {
      if (resolveRef == null) {
        throw ConfigException(
          '$source: queue entry #${i + 1} uses {"ref": ...} but this '
          'source has no customProviders registry to resolve against',
        );
      }
      entry = ProviderQueueEntry.resolvedRef(
        name: item['ref'] as String,
        position: i + 1,
        resolveRef: resolveRef,
        overrides: item['provider_config'] is Map
            ? (item['provider_config'] as Map).cast<Object?, Object?>()
            : null,
      );
    } else {
      entry = ProviderQueueEntry.fromJsonMap(
        item,
        position: i + 1,
        warnings: warnings,
      );
    }
    // Dedup keep-first (UT-duplicates): the full serialized form is the
    // key (E10), so the same provider with two models stays two entries.
    if (!seen.add(entry.dedupKey)) {
      warnings.add(
        '$source: duplicate entry ${entry.label} (#${i + 1}) — '
        'keeping the first occurrence',
      );
      continue;
    }
    entries.add(entry);
  }
  return ParsedProviderQueue(entries: entries, warnings: warnings);
}

/// Parses the `FA_PROVIDERS_QUEUE` env value: a JSON array, or `@path` to
/// load a JSON file ([readText] is injected — this library never touches
/// IO). Whitespace tolerance, BOM stripping, and line/col in JSON errors
/// (UT-parse-env-happy, UT-parse-file-form, E9).
ParsedProviderQueue parseProviderQueueEnv(
  String raw, {
  String source = 'FA_PROVIDERS_QUEUE',
  String? Function(String path) readText = _unreadable,
}) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('@')) {
    final path = trimmed.substring(1).trim();
    final text = readText(path);
    if (text == null) {
      throw ConfigException(
        '$source: cannot read queue file "$path" (relative paths resolve '
        'against the working directory)',
      );
    }
    return parseProviderQueueJsonText(text, source: '$source @${_quote(path)}');
  }
  return parseProviderQueueJsonText(trimmed, source: source);
}

/// Parses a queue JSON text: strict decoding with line/column in every
/// syntax error (UT-parse-strict).
ParsedProviderQueue parseProviderQueueJsonText(
  String text, {
  String source = 'FA_PROVIDERS_QUEUE',
}) {
  final clean = text.replaceFirst('\ufeff', '').trim();
  Object? decoded;
  try {
    decoded = jsonDecode(clean);
  } on FormatException catch (error) {
    final offset = error.offset;
    final position = offset == null || offset < 0 || offset > clean.length
        ? ''
        : ' at line ${_lineOf(clean, offset)}, column ${_columnOf(clean, offset)}';
    final hint = !clean.contains('"') || clean.startsWith("'")
        ? ' — if this came from a shell single-quoted string, the single '
              'quotes are not JSON: wrap the value in single quotes and use '
              'double quotes inside'
        : '';
    throw ConfigException(
      '$source: invalid JSON$position — ${_shortJsonError(error.message)}$hint',
    );
  }
  return parseProviderQueueEntries(decoded, source: source);
}

/// Parses a `providersQueue:` yaml node (the project/user config form).
/// The yaml syntax itself was already checked by the host's [loadYaml];
/// this validates the section shape.
ParsedProviderQueue parseProviderQueueYaml(
  Object? node, {
  required String source,
  ({String kind, String? baseUrl, String model, String? keyName})? Function(
    String name,
  )?
  resolveRef,
}) {
  // YAML maps flow values through YamlMap; a yaml list of maps arrives as
  // YamlList which IS a List — normalize scalar wrappers away so the
  // shared entry parser sees plain Dart values.
  return parseProviderQueueEntries(
    _normalize(node),
    source: source,
    resolveRef: resolveRef,
  );
}

Object? _normalize(Object? node) {
  if (node is YamlList) {
    return [for (final item in node) _normalize(item)];
  }
  if (node is YamlMap) {
    return {
      for (final entry in node.entries)
        entry.key?.toString(): _normalize(entry.value),
    };
  }
  if (node is Map) {
    return {
      for (final entry in node.entries) entry.key: _normalize(entry.value),
    };
  }
  if (node is List) {
    return [for (final item in node) _normalize(item)];
  }
  return node;
}

/// Which source won the scope resolution.
enum ProviderQueueScope { env, project, user }

/// One queue scope's raw availability: a set scope carries its parsed
/// entries (parse errors of ANY set scope fail the boot — a broken shadowed
/// scope is still a misconfiguration worth failing on).
final class ProviderQueueScopeInput {
  /// Creates a scope input.
  const ProviderQueueScopeInput({
    required this.scope,
    required this.isPresent,
    this.parse,
  });

  /// Which scope this describes.
  final ProviderQueueScope scope;

  /// Whether the scope declares a queue at all (env var set / section
  /// present in the file).
  final bool isPresent;

  /// The parsed entries for a present scope (the caller parses each scope
  /// with [parseProviderQueueEnv]/[parseProviderQueueYaml] so errors name
  /// their own source).
  final ParsedProviderQueue? parse;
}

/// The scope-resolution result: the winning queue plus the boot notices
/// (winning scope named, shadowed scopes listed — the `tools:` stack
/// discipline; identical lower scopes collapse into one notice).
final class ProviderQueueResolution {
  /// Creates the resolution.
  const ProviderQueueResolution({
    required this.scope,
    required this.entries,
    required this.notices,
  });

  /// The winning scope.
  final ProviderQueueScope scope;

  /// The winning queue's entries.
  final List<ProviderQueueEntry> entries;

  /// The boot notice lines (already prefixed `note: provider queue ...`).
  final List<String> notices;

  /// Whether a queue is configured at all.
  bool get isSet => entries.isNotEmpty;
}

/// Resolves the queue across scopes: env > project > user > legacy.
///
/// Pass one [ProviderQueueScopeInput] per scope in any order; only present
/// scopes matter. When none is present the result is unset (the legacy
/// `provider:`+`model:` boot continues byte-identical — AC10).
///
/// Shadowed scopes are named in the notices (AC2); a shadowed scope whose
/// queue is semantically identical to the winner collapses into the
/// winner's notice (UT-scope-stack: "project+user identical queues →
/// single notice, no dupes").
ProviderQueueResolution resolveProviderQueueScopes(
  List<ProviderQueueScopeInput> inputs,
) {
  final present = inputs.where((input) => input.isPresent).toList()
    ..sort((a, b) => a.scope.index.compareTo(b.scope.index));
  if (present.isEmpty) {
    return const ProviderQueueResolution(
      scope: ProviderQueueScope.user,
      entries: [],
      notices: [],
    );
  }
  final winner = present.first;
  final entries = winner.parse?.entries ?? const <ProviderQueueEntry>[];
  final notices = <String>[
    'note: provider queue (${entries.length} '
        '${entries.length == 1 ? 'entry' : 'entries'}) from '
        '${_scopeLabel(winner.scope)} — the queue is the main model',
  ];
  final shadowed = present.sublist(1);
  for (final scope in shadowed) {
    final sameQueue = _sameEntries(scope.parse?.entries, entries);
    notices.add(
      sameQueue
          ? 'note: provider queue — ${_scopeLabel(scope.scope)} declares the '
                'same queue (shadowed, no duplicate)'
          : 'note: provider queue — ${_scopeLabel(scope.scope)} is shadowed '
                'by ${_scopeLabel(winner.scope)}',
    );
  }
  return ProviderQueueResolution(
    scope: winner.scope,
    entries: entries,
    notices: notices,
  );
}

bool _sameEntries(List<ProviderQueueEntry>? a, List<ProviderQueueEntry> b) =>
    a != null && a.length == b.length && a.every((e) => b.contains(e));

String _scopeLabel(ProviderQueueScope scope) => switch (scope) {
  ProviderQueueScope.env => 'FA_PROVIDERS_QUEUE env',
  ProviderQueueScope.project => 'project .fah/config.yaml providersQueue:',
  ProviderQueueScope.user => 'user ~/.fah/config.yaml providersQueue:',
};

/// Appends one entry to [entries] after the same strict validation the
/// parsers apply (the editor's add — UT-editor-api). Returns the new list;
/// throws [ConfigException]/[ArgumentError] on invalid input.
List<ProviderQueueEntry> providerQueueAdd(
  List<ProviderQueueEntry> entries,
  ProviderQueueEntry entry,
) {
  if (entries.contains(entry)) {
    throw ConfigException('queue already contains ${entry.label}');
  }
  return [...entries, entry];
}

/// Removes the entry at [index]; throws [RangeError] on a bad index.
List<ProviderQueueEntry> providerQueueRemoveAt(
  List<ProviderQueueEntry> entries,
  int index,
) {
  if (index < 0 || index >= entries.length) {
    throw RangeError.index(index, entries, 'index', null, entries.length);
  }
  return [...entries]..removeAt(index);
}

/// Moves the entry at [index] to [newIndex] (reorder/move-to-head).
List<ProviderQueueEntry> providerQueueMove(
  List<ProviderQueueEntry> entries,
  int index,
  int newIndex,
) {
  if (index < 0 || index >= entries.length) {
    throw RangeError.index(index, entries, 'index', null, entries.length);
  }
  if (newIndex < 0 || newIndex >= entries.length) {
    throw RangeError.index(newIndex, entries, 'newIndex', null, entries.length);
  }
  final next = [...entries];
  final entry = next.removeAt(index);
  next.insert(newIndex, entry);
  return next;
}

/// Serializes [entries] to the yaml body of a `providersQueue:` block
/// (2-space indented list items, no trailing newline) — the surgical
/// write's payload (UT-yaml-roundtrip). Secrets cannot leak: the shape
/// only carries `apiKeyEnv` names.
String providersQueueYamlBody(List<ProviderQueueEntry> entries) {
  final buffer = StringBuffer();
  for (final entry in entries) {
    buffer.writeln('- provider_type: ${entry.providerType}');
    buffer.writeln('  provider_config:');
    buffer.writeln('    model: ${entry.model}');
    if (entry.baseUrl != null) buffer.writeln('    baseUrl: ${entry.baseUrl}');
    if (entry.apiKeyEnv != null) {
      buffer.writeln('    apiKeyEnv: ${entry.apiKeyEnv}');
    }
    if (entry.contextWindow != null) {
      buffer.writeln('    contextWindow: ${entry.contextWindow}');
    }
    if (entry.maxTokens != null) {
      buffer.writeln('    maxTokens: ${entry.maxTokens}');
    }
  }
  return buffer.toString().trimRight();
}

String _typeName(Object? value) => switch (value) {
  null => 'nothing',
  String() => 'a string',
  int() || double() => 'a number',
  bool() => 'a boolean',
  Map() => 'an object',
  List() => 'an array',
  _ => value.runtimeType.toString(),
};

String _quote(String path) => "'$path'";

String? _optionalString(Map<Object?, Object?> map, String key, String where) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw ConfigException('$where: "$key" must be a non-empty string');
  }
  return value.trim();
}

int? _optionalInt(Map<Object?, Object?> map, String key, String where) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw ConfigException('$where: "$key" must be a positive integer');
  }
  return value;
}

int _lineOf(String text, int offset) =>
    text.substring(0, offset).split('\n').length;

int _columnOf(String text, int offset) {
  final lineStart = text.lastIndexOf('\n', offset - 1) + 1;
  return offset - lineStart + 1;
}

String _shortJsonError(String message) {
  final first = message.split('\n').first;
  return first.length <= 160 ? first : '${first.substring(0, 160)}...';
}

String? _unreadable(String path) => null;
