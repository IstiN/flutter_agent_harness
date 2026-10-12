/// Per-skill enable/disable toggles with a tools-like scope stack
/// (issue #1151).
///
/// Mirrors `lib/src/tools/availability.dart` at skill scale: the `skills:`
/// config section accepts `<skill-name>: on|off` entries at the global
/// (`~/.fah/config.yaml`) and project (`.fah/config.yaml`) scopes; the
/// deepest scope mentioning a name wins. Skills default to enabled — unlike
/// tools there is no capability floor (built-in skills are first-party
/// package data and load on every host).
///
/// Pure Dart: no `dart:io`. Resolution returns decisions per discovered
/// skill name; unknown ids (names no discovered skill has) are collected
/// non-fatally — warning about them is the caller's job.
library;

import '../exceptions.dart';
import 'skills.dart';
import 'package:yaml/yaml.dart';

/// Where a skill toggle decision can come from. Resolution precedence is
/// shallow→deep: [SkillToggleScope.global] < [SkillToggleScope.project].
enum SkillToggleScope { global, project }

/// Coerces one `skills:` per-skill entry value into an on/off wish.
/// Accepts booleans and the `on`/`off`/`true`/`false` strings — YAML 1.2
/// parses bare `on`/`off` as strings, and `skills: {create-goal: off}` is
/// the documented shape (issue #1151). Anything else throws
/// [ConfigException] naming the skill.
bool skillToggleValue(String name, Object? value) {
  if (value is bool) return value;
  switch ('$value'.trim().toLowerCase()) {
    case 'on' || 'true':
      return true;
    case 'off' || 'false':
      return false;
    default:
      throw ConfigException(
        'skills.$name must be on/off (or a boolean), got: $value',
      );
  }
}

/// One scope's per-skill `skills:` entries: skill name → on/off.
///
/// Keys are skill names (case-insensitively resolved at resolution time —
/// the canonical entry keeps the last written casing). Values must be
/// booleans; `access`, `disableShellExecution` and `liveRediscovery`
/// (gh-1440) are the section's reserved keys and are NOT accepted here
/// (the CLI config parser handles them alongside this).
final class SkillsConfig {
  SkillsConfig({Map<String, bool> skills = const {}})
    : skills = Map.unmodifiable(skills);

  /// Per-skill on/off wishes.
  final Map<String, bool> skills;

  /// The section's reserved keys — never skill names.
  static const reservedKeys = {
    'access',
    'disableShellExecution',
    'liveRediscovery',
  };

  /// An empty config (no wishes).
  const SkillsConfig.empty() : skills = const {};

  /// Parses a `skills:` yaml node's per-skill entries. [node] must be a
  /// YamlMap (the caller's type gate); every key except the section's
  /// reserved keys is a skill name with a mandatory boolean value.
  factory SkillsConfig.fromYaml(Object? node) {
    if (node == null) return const SkillsConfig.empty();
    if (node is! YamlMap) {
      throw ConfigException('skills must be a map, got: $node');
    }
    final skills = <String, bool>{};
    for (final key in node.keys) {
      final name = '$key';
      if (reservedKeys.contains(name)) continue;
      skills[name] = skillToggleValue(name, node[key]);
    }
    return SkillsConfig(skills: skills);
  }

  /// The `skills:` yaml fragment for these entries (one indented line per
  /// name), for surgical merges into a config file.
  String toYaml() {
    final buffer = StringBuffer();
    for (final entry in skills.entries) {
      buffer.write('  ${entry.key}: ${entry.value}\n');
    }
    return buffer.toString();
  }
}

/// The availability decision for one skill.
final class ResolvedSkillAvailability {
  const ResolvedSkillAvailability({required this.enabled, required this.scope});

  /// Whether the skill is invocable, suggested, and listed for the model.
  final bool enabled;

  /// The deepest scope that mentioned the skill, or null when no scope
  /// declared it (default-on).
  final SkillToggleScope? scope;
}

/// The full resolution over the discovered skills.
final class SkillAvailabilityResolution {
  const SkillAvailabilityResolution({
    required this.byName,
    required this.unknownIds,
  });

  /// Decision per discovered skill name (as discovered — not lowercased).
  final Map<String, ResolvedSkillAvailability> byName;

  /// Toggle names no discovered skill has. Non-fatal; callers warn.
  final Set<String> unknownIds;
}

/// Resolves the scope stack (shallow→deep: global, project) against the
/// discovered [skills]. Default on; the deepest scope mentioning a name
/// wins, matching the tools rule.
SkillAvailabilityResolution resolveSkillAvailability({
  required List<Skill> skills,
  required List<(SkillToggleScope, SkillsConfig)> scopes,
}) {
  final intent = <String, bool>{};
  final intentScope = <String, SkillToggleScope>{};
  final known = <String>{for (final skill in skills) skill.name.toLowerCase()};
  final unknown = <String>{};
  for (final (scope, config) in scopes) {
    for (final entry in config.skills.entries) {
      final name = entry.key.toLowerCase();
      if (!known.contains(name)) {
        unknown.add(entry.key);
        continue;
      }
      intent[name] = entry.value;
      intentScope[name] = scope;
    }
  }
  return SkillAvailabilityResolution(
    byName: {
      for (final skill in skills)
        skill.name: ResolvedSkillAvailability(
          enabled: intent[skill.name.toLowerCase()] ?? true,
          scope: intentScope[skill.name.toLowerCase()],
        ),
    },
    unknownIds: unknown,
  );
}

/// Filters [skills] down to the enabled ones, preserving order.
List<Skill> enabledSkills(
  List<Skill> skills,
  SkillAvailabilityResolution resolution,
) => [
  for (final skill in skills)
    if (resolution.byName[skill.name]?.enabled ?? true) skill,
];
