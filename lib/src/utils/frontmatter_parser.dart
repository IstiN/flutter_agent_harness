/// Shared YAML frontmatter parser for skill/agent markdown files.
/// Extracts the `---`-fenced YAML block as a flat key→string map.
library;

import 'package:yaml/yaml.dart';

/// Parses the `---`-fenced YAML frontmatter block, returning
/// `(key→value map, remaining body)`.
(Map<String, String> frontmatter, String body) parseFrontmatter(String text) {
  final frontmatter = <String, String>{};
  var body = text;
  if (text.startsWith('---')) {
    final end = text.indexOf('\n---', 3);
    if (end > 0) {
      try {
        final doc = loadYaml(text.substring(3, end));
        if (doc is Map) {
          for (final entry in doc.entries) {
            final key = '${entry.key}';
            final value = '${entry.value}'.trim();
            if (value.isNotEmpty) frontmatter[key] = value;
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
