/// Shared YAML frontmatter parser for skill/agent markdown files.
/// Extracts the `---`-fenced YAML block as a flat key→string map.
library;

import 'package:yaml/yaml.dart';

/// Parses the `---`-fenced YAML frontmatter block, returning
/// `(key→value map, remaining body)`.
(Map<String, String> frontmatter, String body) parseFrontmatter(String text) {
  final (typed, body) = parseFrontmatterTyped(text);
  final frontmatter = <String, String>{};
  for (final entry in typed.entries) {
    final value = '${entry.value}'.trim();
    if (value.isNotEmpty) frontmatter[entry.key] = value;
  }
  return (frontmatter, body);
}

/// Parses the `---`-fenced YAML frontmatter block preserving YAML types
/// (lists, booleans, maps), returning `(key→value map, remaining body)`.
/// Values are plain Dart objects (`String`/`num`/`bool`/`List`/`Map`).
/// Bounded memo for parsed YAML frontmatter blocks: skill/agent discovery
/// scans the same markdown files repeatedly across agent runs and sessions.
final _frontmatterCache = <String, Map<String, Object?>>{};
const _frontmatterCacheCapacity = 512;

(Map<String, Object?> frontmatter, String body) parseFrontmatterTyped(
  String text,
) {
  var body = text;
  if (text.startsWith('---')) {
    final end = text.indexOf('\n---', 3);
    if (end > 0) {
      final rawYaml = text.substring(3, end);
      body = text.substring(end + 4).trimLeft();
      final cached = _frontmatterCache[rawYaml];
      if (cached != null) {
        return (_deepCopyMap(cached), body);
      }
      final frontmatter = <String, Object?>{};
      try {
        final doc = loadYaml(rawYaml);
        if (doc is Map) {
          for (final entry in doc.entries) {
            frontmatter['${entry.key}'] = _plainYamlValue(entry.value);
          }
        }
      } on Object {
        // Malformed frontmatter: treat the file as plain body.
      }
      if (rawYaml.length <= 4096) {
        if (_frontmatterCache.length >= _frontmatterCacheCapacity) {
          _frontmatterCache.remove(_frontmatterCache.keys.first);
        }
        _frontmatterCache[rawYaml] = _deepCopyMap(frontmatter);
      }
      return (frontmatter, body);
    }
  }
  return (<String, Object?>{}, body);
}

Map<String, Object?> _deepCopyMap(Map<String, Object?> source) => {
  for (final entry in source.entries) entry.key: _deepCopyValue(entry.value),
};

Object? _deepCopyValue(Object? value) => switch (value) {
  Map<String, Object?>() => _deepCopyMap(value),
  List() => [for (final item in value) _deepCopyValue(item)],
  _ => value,
};

/// Converts a yaml node into a plain Dart value (recursively), so callers
/// never see `YamlMap`/`YamlList` wrappers.
Object? _plainYamlValue(Object? value) {
  return switch (value) {
    Map() => {
      for (final entry in value.entries)
        '${entry.key}': _plainYamlValue(entry.value),
    },
    List() => [for (final item in value) _plainYamlValue(item)],
    _ => value,
  };
}

/// Whether [text]'s frontmatter is well-formed: no `---` fence at the top,
/// or a fence whose YAML loads into a map (or loads to nothing at all —
/// an empty or comment-only fence is well-formed "no metadata": the skill
/// loads with the directory fallback name and an empty description, the
/// pre-gh-1440 behavior; review thread on #1461). An OPENED fence that is
/// never closed counts as malformed — the overwhelmingly likely cause is a
/// torn write (gh-1440 E-1), and indexing the half-written tail as plain
/// body would publish a half-entry.
///
/// Skills discovery uses this to SKIP malformed files with a warning
/// instead of silently indexing them (gh-1440 AC6); the tolerant
/// [parseFrontmatterTyped] behavior is unchanged for every other caller.
bool frontmatterWellFormed(String text) {
  if (!text.startsWith('---')) return true;
  final end = text.indexOf('\n---', 3);
  if (end <= 0) return false;
  try {
    final yaml = loadYaml(text.substring(3, end));
    return yaml == null || yaml is Map;
  } on Object {
    return false;
  }
}
