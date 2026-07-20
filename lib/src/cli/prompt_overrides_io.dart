/// File resolution for prompt overrides (`dart:io`; exported only from
/// `lib/io.dart`): turns the raw `prompts:` config map — values that are a
/// file path OR inline text — into resolved [PromptOverrides] text, and reads
/// the `--system-prompt-file` flag target.
library;

import 'dart:io';

import '../exceptions.dart';
import '../prompts/prompt_overrides.dart';
import 'prompt_templates.dart';

/// Whether a raw `prompts:` value names a file rather than inline text: an
/// absolute path, a `~/` home-relative path, a `./`/`../` relative path, or
/// anything ending in a Markdown/text extension (`.md`, `.markdown`, `.txt`).
bool looksLikePromptFilePath(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('/') ||
      trimmed.startsWith('~/') ||
      trimmed.startsWith('./') ||
      trimmed.startsWith('../') ||
      trimmed.endsWith('.md') ||
      trimmed.endsWith('.markdown') ||
      trimmed.endsWith('.txt');
}

/// Expands a leading `~` to [homeDir] and resolves a relative path against
/// [baseDir].
String resolvePromptFilePath(
  String path, {
  required String homeDir,
  required String baseDir,
}) {
  var resolved = path.trim();
  if (resolved == '~' || resolved.startsWith('~/')) {
    resolved = '$homeDir${resolved.substring(1)}';
  }
  if (resolved.startsWith('/')) return resolved;
  return '$baseDir/$resolved';
}

/// Reads [path] as a prompt override file: YAML frontmatter is stripped (so
/// the `prompts/**` Markdown sources can be copied verbatim as overrides) and
/// the body is trimmed. A missing or unreadable file throws [ConfigException]
/// prefixed with [source] — never a silent fallback.
String loadPromptFile(
  String path, {
  required String homeDir,
  required String baseDir,
  required String source,
}) {
  final resolved = resolvePromptFilePath(
    path,
    homeDir: homeDir,
    baseDir: baseDir,
  );
  final file = File(resolved);
  if (!file.existsSync()) {
    throw ConfigException('$source: prompt file not found: $resolved');
  }
  final String content;
  try {
    content = file.readAsStringSync();
  } on Object catch (error) {
    throw ConfigException('$source: cannot read prompt file $resolved: $error');
  }
  final body = parseFrontmatter(content).body.trim();
  if (body.isEmpty) {
    throw ConfigException('$source: prompt file is empty: $resolved');
  }
  return body;
}

/// Resolves one raw override value: a file path per [looksLikePromptFilePath]
/// (read via [loadPromptFile]), anything else is inline text (trimmed).
String loadPromptOverrideSource(
  String value, {
  required String homeDir,
  required String baseDir,
  required String source,
}) {
  if (!looksLikePromptFilePath(value)) return value.trim();
  return loadPromptFile(
    value,
    homeDir: homeDir,
    baseDir: baseDir,
    source: source,
  );
}

/// Resolves the validated raw `prompts:` map (see [parsePromptOverrideMap])
/// into a [PromptOverrides]. Relative file paths resolve against [baseDir]
/// (the CLI passes the agent cwd); the `system` alias canonicalizes to
/// `cli/mode_code`. Missing files throw [ConfigException].
PromptOverrides resolvePromptOverrides(
  Map<String, String> raw, {
  required String homeDir,
  required String baseDir,
}) {
  if (raw.isEmpty) return PromptOverrides.empty;
  final texts = <String, String>{};
  for (final entry in raw.entries) {
    final name = entry.key == systemPromptAlias
        ? codeModePromptName
        : entry.key;
    texts[name] = loadPromptOverrideSource(
      entry.value,
      homeDir: homeDir,
      baseDir: baseDir,
      source: 'prompts.${entry.key}',
    );
  }
  return PromptOverrides(texts);
}
