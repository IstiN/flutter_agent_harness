/// Prompt templates and mode switching for the `fah` CLI.
///
/// Shaped after pi's prompt-template system (`packages/coding-agent/src/core/
/// prompt-templates.ts`): markdown files with optional YAML frontmatter are
/// loaded from `.fah/prompts/` and the user config directory, then invoked by
/// typing `/name <args>` in the REPL. Built-in system-prompt modes (`/architect`,
/// `/code`, `/review`) are also provided; their prompt templates are Markdown
/// files under `prompts/cli/` in this repository (see AGENTS.md), compiled
/// into `../prompts/prompts.g.dart`.
library;

import 'dart:async';

import 'package:yaml/yaml.dart' as yaml;

import '../env/execution_env.dart';
import '../prompts/prompt_overrides.dart';
import '../prompts/prompts.g.dart';

/// A prompt template loaded from a markdown file.
final class PromptTemplate {
  /// Creates a prompt template.
  const PromptTemplate({
    required this.name,
    required this.description,
    this.argumentHint,
    required this.content,
    required this.filePath,
  });

  /// Command name (filename without `.md`).
  final String name;

  /// Short description from frontmatter or first content line.
  final String description;

  /// Optional argument hint for help text.
  final String? argumentHint;

  /// Template body, after frontmatter removal.
  final String content;

  /// Absolute or resolved path to the template file.
  final String filePath;

  @override
  String toString() => 'PromptTemplate($name)';
}

/// Parses bash-style quoted arguments from the text after a `/command`.
List<String> parseCommandArgs(String input) {
  final args = <String>[];
  var current = '';
  String? inQuote;

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (inQuote != null) {
      if (char == inQuote) {
        inQuote = null;
      } else {
        current += char;
      }
    } else if (char == '"' || char == "'") {
      inQuote = char;
    } else if (RegExp(r'\s').hasMatch(char)) {
      if (current.isNotEmpty) {
        args.add(current);
        current = '';
      }
    } else {
      current += char;
    }
  }
  if (current.isNotEmpty) args.add(current);
  return args;
}

/// Substitutes positional arguments into a template body.
///
/// Supports:
/// - `$1`, `$2`, ... positional args
/// - `$@` and `$ARGUMENTS` for all args joined by a space
/// - `${N:-default}` for arg N with a default when missing/empty
/// - `${@:N}` for args from N onwards
/// - `${@:N:L}` for L args starting at N
String substituteArgs(String content, List<String> args) {
  final allArgs = args.join(' ');
  return content.replaceAllMapped(
    RegExp(
      r'\$\{(\d+):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)',
    ),
    (match) {
      final defaultNum = match.group(1);
      final defaultValue = match.group(2);
      final sliceStart = match.group(3);
      final sliceLength = match.group(4);
      final simple = match.group(5);

      if (defaultNum != null) {
        final index = int.parse(defaultNum) - 1;
        final value = index >= 0 && index < args.length ? args[index] : null;
        return (value?.isNotEmpty ?? false) ? value! : (defaultValue ?? '');
      }

      if (sliceStart != null) {
        var start = int.parse(sliceStart) - 1;
        if (start < 0) start = 0;
        if (sliceLength != null) {
          final length = int.parse(sliceLength);
          return args.slice(start, start + length).join(' ');
        }
        return args.sublist(start).join(' ');
      }

      if (simple == 'ARGUMENTS' || simple == '@') return allArgs;

      final index = int.parse(simple!) - 1;
      return index >= 0 && index < args.length ? args[index] : '';
    },
  );
}

/// Splits markdown content into YAML frontmatter and body.
({Map<String, dynamic> frontmatter, String body}) parseFrontmatter(
  String content,
) {
  const separator = '---';
  if (!content.startsWith('$separator\n') &&
      !content.startsWith('$separator\r\n')) {
    return (frontmatter: <String, dynamic>{}, body: content);
  }
  final endIndex = content.indexOf('\n$separator', separator.length);
  if (endIndex == -1) return (frontmatter: <String, dynamic>{}, body: content);
  final frontYaml = content.substring(separator.length + 1, endIndex).trim();
  final body = content.substring(endIndex + separator.length + 2).trim();
  try {
    final parsed = yaml.loadYaml(frontYaml);
    if (parsed is Map) {
      return (
        frontmatter: Map<String, dynamic>.fromEntries(
          parsed.entries.map(
            (e) => MapEntry<String, dynamic>(e.key.toString(), e.value),
          ),
        ),
        body: body,
      );
    }
  } on Object {
    // ignore: invalid frontmatter, fall through
  }
  return (frontmatter: <String, dynamic>{}, body: content);
}

Future<PromptTemplate?> _loadTemplateFromFile(
  ExecutionEnv env,
  String filePath,
) async {
  final read = await env.readTextFile(filePath);
  if (read.isErr) return null;
  final raw = read.valueOrNull!;
  final name = filePath.split('/').last.replaceFirst(RegExp(r'\.md$'), '');
  final (:frontmatter, :body) = parseFrontmatter(raw);

  var description = (frontmatter['description'] as String?) ?? '';
  if (description.isEmpty) {
    final firstLine = body
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isNotEmpty) {
      description = firstLine.length > 60
          ? '${firstLine.substring(0, 60)}...'
          : firstLine;
    }
  }

  return PromptTemplate(
    name: name,
    description: description,
    argumentHint: frontmatter['argument-hint'] as String?,
    content: body,
    filePath: filePath,
  );
}

Future<List<PromptTemplate>> _loadTemplatesFromDir(
  ExecutionEnv env,
  String dir,
) async {
  final templates = <PromptTemplate>[];
  final list = await env.listDir(dir);
  if (list.isErr) return templates;
  for (final info in list.valueOrNull!) {
    if (info.kind != FileKind.file || !info.name.endsWith('.md')) continue;
    final template = await _loadTemplateFromFile(env, info.path);
    if (template != null) templates.add(template);
  }
  return templates;
}

/// Loads prompt templates from a list of directories.
///
/// Directories are scanned non-recursively for `.md` files. Missing or
/// unreadable directories are ignored.
Future<List<PromptTemplate>> loadPromptTemplates(
  ExecutionEnv env,
  List<String> dirs,
) async {
  final templates = <PromptTemplate>[];
  for (final dir in dirs) {
    final exists = await env.exists(dir);
    if (exists.isErr || !exists.valueOrNull!) continue;
    templates.addAll(await _loadTemplatesFromDir(env, dir));
  }
  return templates;
}

/// Expands a `/name args...` template invocation if it matches a known
/// template. Returns [text] unchanged when it is not a template command.
String expandPromptTemplate(String text, List<PromptTemplate> templates) {
  if (!text.startsWith('/')) return text;
  final match = RegExp(r'^/([^\s]+)(?:\s+([\s\S]*))?$').firstMatch(text);
  if (match == null) return text;
  final name = match.group(1)!;
  final argsString = match.group(2) ?? '';
  final template = templates.firstWhereOrNull((t) => t.name == name);
  if (template == null) return text;
  return substituteArgs(template.content, parseCommandArgs(argsString));
}

/// A system-prompt mode for the CLI (e.g. `/architect`, `/code`, `/review`).
final class AgentMode {
  /// Creates an agent mode.
  const AgentMode({
    required this.name,
    required this.description,
    required this.systemPrompt,
  });

  /// Mode command name (without the leading `/`).
  final String name;

  /// Short help description.
  final String description;

  /// Full system prompt used while this mode is active.
  final String systemPrompt;
}

/// Substitutes the working directory into a mode prompt template.
///
/// The templates live outside Dart code in `prompts/cli/` (see AGENTS.md) and
/// carry a `{{cwd}}` placeholder that is replaced here. Prompt overrides go
/// through the same substitution, so an override file may use `{{cwd}}` too.
String _modePrompt(String template, String cwd) =>
    template.replaceAll('{{cwd}}', cwd);

/// The default coding-agent mode.
///
/// [overrides] (from the CLI config `prompts:` section) replaces the built-in
/// prompt when it names this mode.
AgentMode defaultAgentMode(String cwd, {PromptOverrides? overrides}) =>
    AgentMode(
      name: 'code',
      description: 'General coding assistant mode (default).',
      systemPrompt: _modePrompt(
        overrides?.resolve(codeModePromptName, cliCodeModePrompt) ??
            cliCodeModePrompt,
        cwd,
      ),
    );

/// High-level design and planning mode.
AgentMode architectMode(String cwd, {PromptOverrides? overrides}) => AgentMode(
  name: 'architect',
  description: 'High-level design, trade-offs, and planning.',
  systemPrompt: _modePrompt(
    overrides?.resolve(architectModePromptName, cliArchitectModePrompt) ??
        cliArchitectModePrompt,
    cwd,
  ),
);

/// Code-review mode.
AgentMode reviewMode(String cwd, {PromptOverrides? overrides}) => AgentMode(
  name: 'review',
  description: 'Review code for correctness, security, and maintainability.',
  systemPrompt: _modePrompt(
    overrides?.resolve(reviewModePromptName, cliReviewModePrompt) ??
        cliReviewModePrompt,
    cwd,
  ),
);

/// All built-in modes keyed by name.
Map<String, AgentMode> builtInAgentModes(
  String cwd, {
  PromptOverrides? overrides,
}) => {
  defaultAgentMode(cwd, overrides: overrides).name: defaultAgentMode(
    cwd,
    overrides: overrides,
  ),
  architectMode(cwd, overrides: overrides).name: architectMode(
    cwd,
    overrides: overrides,
  ),
  reviewMode(cwd, overrides: overrides).name: reviewMode(
    cwd,
    overrides: overrides,
  ),
};

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

extension _ListSlice<T> on List<T> {
  List<T> slice(int start, int end) {
    final s = start.clamp(0, length);
    final e = end.clamp(s, length);
    return sublist(s, e);
  }
}
