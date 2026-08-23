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
(Map<String, Object?> frontmatter, String body) parseFrontmatterTyped(
  String text,
) {
  final frontmatter = <String, Object?>{};
  var body = text;
  if (text.startsWith('---')) {
    final end = text.indexOf('\n---', 3);
    if (end > 0) {
      try {
        final doc = loadYaml(text.substring(3, end));
        if (doc is Map) {
          for (final entry in doc.entries) {
            frontmatter['${entry.key}'] = _plainYamlValue(entry.value);
          }
        }
      } on Object {
        // Malformed frontmatter: treat the file as plain body.
      }
      body = text.substring(end + 4).trimLeft();
    }
  }
  return (frontmatter, body);
}

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
