/// Renders a skill body for invocation: argument substitutions
/// (`$ARGUMENTS`, `$ARGUMENTS[N]`, `$N`, `$name`, `${CLAUDE_*}`) and
/// Claude-style dynamic context injection (`!`cmd`` lines and ```` ```! ````
/// fenced blocks executed through the host shell before the content is sent
/// to the model).
///
/// Substitution runs once over the file; injected command output is inserted
/// as plain text and is NOT re-scanned for further placeholders (Claude
/// semantics). A failed injected command aborts the whole invocation with a
/// [SkillRenderException].
library;

import '../env/execution_env.dart';
import '../utils/frontmatter_parser.dart';
import 'skills.dart';

/// Thrown when a skill cannot be rendered (e.g. an injected shell command
/// failed). The message is user/agent-facing text.
final class SkillRenderException implements Exception {
  const SkillRenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The outcome of [renderSkillBody].
final class SkillRenderResult {
  const SkillRenderResult({required this.body, this.notes = const []});

  /// The fully rendered skill body (frontmatter stripped, substitutions and
  /// injections applied).
  final String body;

  /// Non-fatal notes (e.g. shell execution disabled by policy).
  final List<String> notes;
}

/// Splits an argument string shell-style: double quotes group a token,
/// backslash escapes the next char inside quotes.
List<String> splitSkillArguments(String args) {
  final result = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var hasToken = false;
  for (var i = 0; i < args.length; i++) {
    final char = args[i];
    if (inQuotes) {
      if (char == '"') {
        inQuotes = false;
      } else if (char == '\\' && i + 1 < args.length) {
        current.write(args[++i]);
      } else {
        current.write(char);
      }
    } else if (char == '"') {
      inQuotes = true;
      hasToken = true;
    } else if (char.trim().isEmpty) {
      if (hasToken || current.isNotEmpty) {
        result.add(current.toString());
        current.clear();
        hasToken = false;
      }
    } else {
      current.write(char);
    }
  }
  if (hasToken || current.isNotEmpty) result.add(current.toString());
  return result;
}

/// Renders [skill]'s body for one invocation.
///
/// - [args] is the raw argument string (after the skill name); [argList]
///   overrides positional splitting when the caller already parsed it.
/// - [sessionId]/[projectDir] fill `${CLAUDE_SESSION_ID}` /
///   `${CLAUDE_PROJECT_DIR}`; `${CLAUDE_SKILL_DIR}` always resolves to the
///   skill's directory.
/// - [shellExecutionEnabled] false replaces every injection with the
///   disabled-by-policy placeholder instead of executing it.
Future<SkillRenderResult> renderSkillBody(
  ExecutionEnv env,
  Skill skill, {
  String args = '',
  List<String>? argList,
  String? sessionId,
  String? projectDir,
  bool shellExecutionEnabled = true,
}) async {
  final text = (await env.readTextFile(skill.filePath)).valueOrNull;
  if (text == null) {
    throw SkillRenderException('cannot read skill file: ${skill.filePath}');
  }
  final (frontmatter, rawBody) = parseFrontmatterTyped(text);
  // Re-parse so a hand-constructed Skill keeps in sync with the file.
  final manifest =
      skill.manifest == SkillManifest.empty && frontmatter.isNotEmpty
      ? SkillManifest.fromFrontmatter(frontmatter, skillName: skill.name)
      : skill.manifest;

  final positional = argList ?? splitSkillArguments(args);
  var body = _substituteVariables(
    rawBody,
    skill: skill,
    manifest: manifest,
    args: args,
    positional: positional,
    sessionId: sessionId,
    projectDir: projectDir,
  );

  final notes = <String>[];
  if (!shellExecutionEnabled &&
      (_inlineInjectionPattern.hasMatch(body) || body.contains('```!'))) {
    notes.add('shell command execution disabled by policy');
  }
  body = await _injectShellCommands(
    env,
    body,
    shellExecutionEnabled: shellExecutionEnabled,
  );
  return SkillRenderResult(body: body.trim(), notes: notes);
}

final _inlineInjectionPattern = RegExp(r'(^|\n)(\s*)!`([^`\n]+)`');

String _substituteVariables(
  String body, {
  required Skill skill,
  required SkillManifest manifest,
  required String args,
  required List<String> positional,
  String? sessionId,
  String? projectDir,
}) {
  var out = body;
  var usedArguments = false;

  String indexed(int i) => i < positional.length ? positional[i] : '';
  // ${CLAUDE_*} environment-style variables first (independent of \$ escape).
  out = out
      .replaceAll(r'${CLAUDE_SESSION_ID}', sessionId ?? '')
      .replaceAll(r'${CLAUDE_PROJECT_DIR}', projectDir ?? '')
      .replaceAll(r'${CLAUDE_SKILL_DIR}', skill.directory);

  // $ARGUMENTS[N] and $N (longest first so $ARGUMENTS doesn't eat [N]).
  out = out.replaceAllMapped(RegExp(r'(?<!\\)\$ARGUMENTS\[(\d+)\]'), (m) {
    usedArguments = true;
    return indexed(int.parse(m[1]!));
  });
  out = out.replaceAllMapped(RegExp(r'(?<!\\)\$ARGUMENTS\b'), (m) {
    usedArguments = true;
    return args;
  });
  out = out.replaceAllMapped(RegExp(r'(?<!\\)\$(\d+)'), (m) {
    usedArguments = true;
    return indexed(int.parse(m[1]!));
  });
  // Named arguments from the frontmatter `arguments:` list.
  for (var i = 0; i < manifest.arguments.length; i++) {
    final name = manifest.arguments[i];
    out = out.replaceAllMapped(RegExp('(?<!\\\\)\\\$$name\\b'), (m) {
      usedArguments = true;
      return i < positional.length ? positional[i] : '';
    });
  }
  // Backslash-escaped placeholders become literal.
  out = out.replaceAll('\\\$', '\u0000').replaceAll('\u0000', r'$');

  if (args.isNotEmpty && !usedArguments) {
    out = '${out.trimRight()}\n\nARGUMENTS: $args';
  }
  return out;
}

/// Executes `!`cmd`` inline injections and ```` ```! ```` fenced blocks,
/// replacing each with the command output (stdout + stderr merged).
Future<String> _injectShellCommands(
  ExecutionEnv env,
  String body, {
  required bool shellExecutionEnabled,
}) async {
  Future<String> run(String command) async {
    if (!shellExecutionEnabled) {
      return '[shell command execution disabled by policy]';
    }
    final result = await env.exec(
      command,
      options: const ShellExecOptions(timeout: Duration(minutes: 2)),
    );
    final value = result.valueOrNull;
    if (value == null) {
      throw SkillRenderException(
        'Shell command failed for pattern "$command": '
        '${result.errorOrNull?.message ?? 'unavailable'}',
      );
    }
    final output = value.stderr.isEmpty
        ? value.stdout
        : '${value.stdout}${value.stderr}';
    if (value.exitCode != 0) {
      throw SkillRenderException(
        'Shell command failed for pattern "$command" '
        '(exit ${value.exitCode}):\n$output',
      );
    }
    return output.trimRight();
  }

  // Fenced blocks first: ```!\n<commands>\n``` → each line is a command run
  // in sequence, outputs concatenated (Claude runs the block as one script).
  final fenced = RegExp(r'```!\n([\s\S]*?)```');
  var out = body;
  final fencedMatches = fenced.allMatches(out).toList();
  for (var i = fencedMatches.length - 1; i >= 0; i--) {
    final m = fencedMatches[i];
    out = out.replaceRange(m.start, m.end, await run(m[1]!.trim()));
  }
  // Inline: `!` must start a line or follow whitespace (Claude rule).
  final inlineMatches = _inlineInjectionPattern.allMatches(out).toList();
  for (var i = inlineMatches.length - 1; i >= 0; i--) {
    final m = inlineMatches[i];
    out = out.replaceRange(
      m.start + m[1]!.length,
      m.end,
      '${m[2]}${await run(m[3]!)}',
    );
  }
  return out;
}
