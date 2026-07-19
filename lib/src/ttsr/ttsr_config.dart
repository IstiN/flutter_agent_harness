/// YAML config surface for TTSR: the `ttsr:` section of `~/.fah/config.yaml`
/// (settings + rules) and the project-level `.fah/rules.yaml` (rules only).
///
/// Mirrors the strictness of the model-roles config: a malformed `ttsr:`
/// section throws [ConfigException] instead of silently resetting (bad rules
/// must surface), while an invalid regex inside an otherwise well-formed
/// rule follows omp — collected as a warning and skipped at registration.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../exceptions.dart';
import 'ttsr_manager.dart';
import 'ttsr_rule.dart';

/// A parsed TTSR configuration: manager settings plus the rules to monitor.
final class TtsrConfig {
  /// Creates a config.
  const TtsrConfig({
    this.settings = TtsrSettings.defaultSettings,
    this.rules = const [],
  });

  /// Manager settings.
  final TtsrSettings settings;

  /// Rules to register (registration order matters: the manager dedupes by
  /// name, first wins — hosts put project rules ahead of user rules).
  final List<TtsrRule> rules;

  /// Parses the `ttsr:` section of the CLI config (settings + rules).
  ///
  /// [sourcePath] becomes the provenance [TtsrRule.path] of rules that don't
  /// declare their own. Throws [ConfigException] on malformed structure.
  factory TtsrConfig.fromYaml(
    Object? node, {
    String? sourcePath,
    List<String>? warnings,
  }) {
    if (node is! YamlMap) {
      throw const ConfigException('"ttsr" must be a map');
    }
    return TtsrConfig(
      settings: _parseSettings(node),
      rules: rulesFromYamlList(
        node['rules'],
        sourcePath: sourcePath,
        warnings: warnings,
        section: 'ttsr.rules',
      ),
    );
  }

  /// Parses a project rules file (`.fah/rules.yaml`): a map with a `rules:`
  /// list and no settings.
  static List<TtsrRule> rulesFromYaml(
    Object? node, {
    String? sourcePath,
    List<String>? warnings,
  }) {
    if (node is! YamlMap) {
      throw const ConfigException(
        'rules file must be a map with a "rules" list',
      );
    }
    return rulesFromYamlList(
      node['rules'],
      sourcePath: sourcePath,
      warnings: warnings,
      section: 'rules',
    );
  }

  /// Parses a yaml rule list (shared by the config section and the project
  /// file).
  static List<TtsrRule> rulesFromYamlList(
    Object? node, {
    String? sourcePath,
    List<String>? warnings,
    required String section,
  }) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw ConfigException('"$section" must be a list');
    }
    final collected = warnings ?? <String>[];
    return [
      for (var i = 0; i < node.length; i++)
        _parseRule(node[i], '$section[$i]', sourcePath, collected),
    ];
  }

  static TtsrSettings _parseSettings(YamlMap map) {
    final contextModeRaw = map['contextMode'];
    final contextMode = contextModeRaw == null
        ? TtsrContextMode.discard
        : TtsrSettings.contextModeFromLabel('$contextModeRaw');
    if (contextMode == null) {
      throw ConfigException(
        '"ttsr.contextMode" must be discard|keep, got "$contextModeRaw"',
      );
    }
    final repeatModeRaw = map['repeatMode'];
    final repeatMode = repeatModeRaw == null
        ? TtsrRepeatMode.once
        : TtsrSettings.repeatModeFromLabel('$repeatModeRaw');
    if (repeatMode == null) {
      throw ConfigException(
        '"ttsr.repeatMode" must be once|after-gap, got "$repeatModeRaw"',
      );
    }
    return TtsrSettings(
      enabled: _bool(map['enabled'], 'ttsr.enabled', fallback: true),
      contextMode: contextMode,
      repeatMode: repeatMode,
      repeatGap: _int(map['repeatGap'], 'ttsr.repeatGap', fallback: 10, min: 0),
      maxInjectionsPerTurn: _int(
        map['maxInjectionsPerTurn'],
        'ttsr.maxInjectionsPerTurn',
        fallback: 3,
        min: 1,
      ),
      retryDelay: Duration(
        milliseconds: _int(
          map['retryDelayMs'],
          'ttsr.retryDelayMs',
          fallback: 50,
          min: 0,
        ),
      ),
    );
  }

  static TtsrRule _parseRule(
    Object? node,
    String where,
    String? sourcePath,
    List<String> warnings,
  ) {
    if (node is! YamlMap) {
      throw ConfigException('"$where" must be a map');
    }
    final name = node['name'];
    if (name is! String || name.trim().isEmpty) {
      throw ConfigException('"$where.name" must be a non-empty string');
    }
    final patterns = _stringList(node['pattern'] ?? node['patterns']);
    if (patterns == null || patterns.isEmpty) {
      throw ConfigException(
        '"$where.pattern" must be a regex string or a non-empty list',
      );
    }
    final body = node['body'];
    if (body is! String || body.isEmpty) {
      throw ConfigException('"$where.body" must be a non-empty string');
    }
    final path = node['path'];
    if (path != null && path is! String) {
      throw ConfigException('"$where.path" must be a string');
    }
    final scopeTokens = _stringList(node['scope']);
    return TtsrRule(
      name: name.trim(),
      patterns: patterns,
      body: body,
      path: (path as String?) ?? sourcePath,
      enabled: _bool(node['enabled'], '$where.enabled', fallback: true),
      scope: TtsrScope.parse(
        scopeTokens,
        ruleName: name.trim(),
        warnings: warnings,
      ),
    );
  }

  /// Accepts a single string or a yaml list of strings (omp's
  /// `condition: string | string[]`).
  static List<String>? _stringList(Object? node) {
    if (node == null) return null;
    if (node is String) return node.trim().isEmpty ? null : [node];
    if (node is! YamlList) return null;
    final tokens = [
      for (final entry in node)
        if (entry is String && entry.trim().isNotEmpty) entry,
    ];
    return tokens.isEmpty ? null : tokens;
  }

  static bool _bool(Object? node, String where, {required bool fallback}) {
    if (node == null) return fallback;
    if (node is! bool) {
      throw ConfigException('"$where" must be a boolean');
    }
    return node;
  }

  static int _int(
    Object? node,
    String where, {
    required int fallback,
    required int min,
  }) {
    if (node == null) return fallback;
    if (node is! int || node < min) {
      throw ConfigException('"$where" must be an integer >= $min');
    }
    return node;
  }

  /// Serializes back to the `ttsr:` yaml section (round-trips with
  /// [TtsrConfig.fromYaml]); strings are JSON-quoted, which yaml parses
  /// identically.
  String toYaml() {
    final buffer = StringBuffer()
      ..write('ttsr:\n')
      ..write('  enabled: ${settings.enabled}\n')
      ..write(
        '  contextMode: '
        '${settings.contextMode == TtsrContextMode.keep ? 'keep' : 'discard'}\n',
      )
      ..write(
        '  repeatMode: '
        '${settings.repeatMode == TtsrRepeatMode.afterGap ? 'after-gap' : 'once'}\n',
      )
      ..write('  repeatGap: ${settings.repeatGap}\n')
      ..write('  maxInjectionsPerTurn: ${settings.maxInjectionsPerTurn}\n')
      ..write('  retryDelayMs: ${settings.retryDelay.inMilliseconds}\n');
    if (rules.isEmpty) {
      buffer.write('  rules: []\n');
    } else {
      buffer.write('  rules:\n');
      for (final rule in rules) {
        buffer
          ..write('    - name: ${jsonEncode(rule.name)}\n')
          ..write('      pattern: ${jsonEncode(rule.patterns)}\n')
          ..write('      body: ${jsonEncode(rule.body)}\n');
        if (rule.path != null) {
          buffer.write('      path: ${jsonEncode(rule.path)}\n');
        }
        if (!rule.enabled) buffer.write('      enabled: false\n');
        final scopeTokens = _scopeTokens(rule.scope);
        if (scopeTokens != null) {
          buffer.write('      scope: ${jsonEncode(scopeTokens)}\n');
        }
      }
    }
    return buffer.toString();
  }

  static List<String>? _scopeTokens(TtsrScope scope) {
    if (scope.allowText &&
        !scope.allowThinking &&
        scope.allowAnyTool &&
        scope.toolNames.isEmpty) {
      return null; // the default scope
    }
    return [
      if (scope.allowText) 'text',
      if (scope.allowThinking) 'thinking',
      if (scope.allowAnyTool) 'tool',
      for (final name in scope.toolNames) 'tool:$name',
    ];
  }
}
