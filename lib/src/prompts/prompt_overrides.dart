/// Prompt overrides: user-supplied replacements for the built-in LLM prompts.
///
/// The CLI config (`~/.fah/config.yaml`) may carry a `prompts:` section
/// mapping prompt names to override sources — a Markdown file path or inline
/// text:
///
/// ```yaml
/// prompts:
///   system: ~/prompts/my_system.md      # alias for cli/mode_code
///   cli/mode_review: "You are a terse reviewer."
///   compaction/summary: ./prompts/summary.md
/// ```
///
/// This library is the pure-Dart core: the name registry, the strict raw-map
/// validation ([parsePromptOverrideMap]), and the resolved [PromptOverrides]
/// threaded through the consumption points (CLI mode prompts and compaction
/// summarization). Reading override files needs `dart:io` and lives in
/// `src/cli/prompt_overrides_io.dart` (exported from `lib/io.dart`); the
/// per-invocation `--system-prompt`/`--system-prompt-file` flags are parsed
/// in `src/cli/cli_args.dart`.
library;

import '../exceptions.dart';

/// The `system` config key: an alias for [codeModePromptName] (the base CLI
/// system prompt).
const systemPromptAlias = 'system';

/// Canonical prompt name for the CLI code mode (the default mode).
const codeModePromptName = 'cli/mode_code';

/// Canonical prompt name for the CLI architect mode.
const architectModePromptName = 'cli/mode_architect';

/// Canonical prompt name for the CLI review mode.
const reviewModePromptName = 'cli/mode_review';

/// The prompt names accepted in the CLI config `prompts:` section, mapped to
/// a short description. Names mirror the `prompts/` tree ids used by
/// `scripts/gen_prompts.dart`; [systemPromptAlias] is an alias for
/// [codeModePromptName].
///
/// Only the prompts the CLI actually resolves through [PromptOverrides] are
/// listed: the mode system prompts and the compaction summarization prompts.
const overridablePromptNames = <String, String>{
  systemPromptAlias: 'Alias for cli/mode_code (the base CLI system prompt).',
  codeModePromptName: 'System prompt for code mode (the default mode).',
  architectModePromptName: 'System prompt for architect mode.',
  reviewModePromptName: 'System prompt for review mode.',
  'compaction/summary_system':
      'System prompt of the compaction summarization call.',
  'compaction/summary': 'Compaction instructions for the first summary.',
  'compaction/summary_update':
      'Compaction instructions for updating a previous summary.',
  'compaction/turn_prefix':
      'Compaction instructions for a split-turn prefix summary.',
};

/// Validates the raw `prompts:` yaml section into a prompt name → raw source
/// map (values stay raw: a file path or inline text — classified later, at
/// file-resolution time).
///
/// Strict, like the `roles:`/`ttsr:` sections: a non-map section, a
/// non-string or empty value, an unknown prompt name, or [systemPromptAlias]
/// given together with [codeModePromptName] throws [ConfigException] instead
/// of silently dropping the section. A null [node] (absent section) yields an
/// empty map.
Map<String, String> parsePromptOverrideMap(Object? node) {
  if (node == null) return const {};
  if (node is! Map) {
    throw ConfigException(
      '"prompts" must be a map of prompt name → file path or inline text',
    );
  }
  final result = <String, String>{};
  for (final entry in node.entries) {
    final name = entry.key;
    final value = entry.value;
    if (name is! String || !overridablePromptNames.containsKey(name)) {
      throw ConfigException(
        'unknown prompt override "$name" — supported names: '
        '${overridablePromptNames.keys.join(', ')}',
      );
    }
    if (value is! String || value.trim().isEmpty) {
      throw ConfigException(
        '"prompts.$name" must be a non-empty string '
        '(a file path or inline text)',
      );
    }
    result[name] = value;
  }
  if (result.containsKey(systemPromptAlias) &&
      result.containsKey(codeModePromptName)) {
    throw ConfigException(
      '"prompts" maps both "$systemPromptAlias" and "$codeModePromptName" — '
      'they are aliases for the same prompt; keep only one',
    );
  }
  return result;
}

/// Resolved prompt overrides: canonical prompt name → override text.
///
/// Produced from the validated raw map by `resolvePromptOverrides` (see
/// `src/cli/prompt_overrides_io.dart`) or constructed directly in tests.
/// Consumption points call [resolve] with the built-in prompt as the
/// fallback, so [PromptOverrides.empty] reproduces the built-in behavior
/// byte-for-byte.
final class PromptOverrides {
  /// Creates resolved overrides from a canonical name → text map.
  const PromptOverrides(this._texts);

  /// No overrides — every [resolve] returns its fallback.
  static const empty = PromptOverrides(<String, String>{});

  final Map<String, String> _texts;

  /// Whether there are no overrides.
  bool get isEmpty => _texts.isEmpty;

  /// The overridden prompt names (canonical).
  Iterable<String> get names => _texts.keys;

  /// The override text for [name], or null when [name] is not overridden.
  String? operator [](String name) => _texts[name];

  /// The override text for [name], or [fallback] when not overridden.
  String resolve(String name, String fallback) => _texts[name] ?? fallback;
}
