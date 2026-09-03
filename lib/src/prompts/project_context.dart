/// Project context files (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `GOAL.md`,
/// `DESIGN.md`) auto-included in the system prompt (ported, reduced, from
/// pi's `core/resource-loader.ts` and kimi-cli's `load_agents_md`).
///
/// Discovery walks the working directory upward to the git root (a directory
/// containing `.git`; the filesystem root is the hard stop), collecting every
/// matching file per directory — pi walks all ancestors; kimi annotates each
/// part with `<!-- From: -->` and caps the merged content leaf-first. Files
/// merge farthest-first so the closest (most specific) instructions read
/// last. Reads go through [ExecutionEnv], so the feature works on every
/// host (desktop, mobile, web sandbox).
///
/// Per walked directory the GitHub Copilot files are collected too:
/// `.github/copilot-instructions.md` (unscoped) and every
/// `.github/instructions/*.instructions.md` file. The instructions files'
/// YAML frontmatter `applyTo` globs are NOT evaluated (there is no
/// touched-file context at prompt-build time): an `applyTo`-less file (or
/// `applyTo: "**"`) is included verbatim, a scoped one is included with an
/// `<!-- applies to: ... -->` marker so the model sees the scoping.
/// `excludeAgent` is accepted but ignored — the merged prompt serves every
/// agent role.
library;

import 'package:flutter_sandbox/flutter_sandbox.dart';
import '../utils/frontmatter_parser.dart';

/// The context filenames collected per directory, in priority order (all
/// present files are included, each as its own block).
const projectContextFileNames = [
  'AGENTS.md',
  'CLAUDE.md',
  'GEMINI.md',
  'GOAL.md',
  'DESIGN.md',
];

/// The merged-content budget, allocated leaf-first so deeper (more
/// specific) files are never truncated in favor of shallower ones
/// (kimi's `_AGENTS_MD_MAX_BYTES`).
const projectContextMaxBytes = 32 * 1024;

/// One discovered context file.
final class ProjectContextFile {
  const ProjectContextFile({required this.path, required this.content});

  /// Absolute path of the file.
  final String path;

  /// Verbatim file content.
  final String content;
}

/// Loads every [projectContextFileNames] file walking from [cwd] up to the
/// git root (or the filesystem root). Returns files farthest-first, closest
/// (most specific) last. A [userFile] (e.g. `~/.fah/AGENTS.md`) is merged
/// first when present (pi's global layer).
Future<List<ProjectContextFile>> loadProjectContextFiles(
  ExecutionEnv env, {
  String? userFile,
}) async {
  final found = <ProjectContextFile>[];

  // Walk cwd upward, collecting per-directory matches (closest first).
  final byDir = <List<ProjectContextFile>>[];
  var dir = env.cwd;
  for (;;) {
    final dirFiles = await _contextFilesInDir(env, dir);
    if (dirFiles.isNotEmpty) byDir.add(dirFiles);
    if ((await env.exists('$dir/.git')).valueOrNull ?? false) break;
    final parent = _parentOf(dir);
    if (parent == dir) break;
    dir = parent;
  }

  final user = await _loadUserFile(env, userFile);
  if (user != null) found.add(user);
  // Farthest first, closest (most specific) last.
  for (final dirFiles in byDir.reversed) {
    found.addAll(dirFiles);
  }
  return _applyBudget(found);
}

/// Collects the present, non-empty [projectContextFileNames] files of one
/// directory, followed by the GitHub Copilot files
/// (`.github/copilot-instructions.md`, then `.github/instructions/
/// *.instructions.md` sorted by name).
Future<List<ProjectContextFile>> _contextFilesInDir(
  ExecutionEnv env,
  String dir,
) async {
  final dirFiles = <ProjectContextFile>[];
  for (final name in projectContextFileNames) {
    final path = '$dir/$name';
    final content = (await env.readTextFile(path)).valueOrNull;
    if (content != null && content.trim().isNotEmpty) {
      dirFiles.add(ProjectContextFile(path: path, content: content));
    }
  }

  final copilotPath = '$dir/.github/copilot-instructions.md';
  final copilot = (await env.readTextFile(copilotPath)).valueOrNull;
  if (copilot != null && copilot.trim().isNotEmpty) {
    dirFiles.add(ProjectContextFile(path: copilotPath, content: copilot));
  }

  final instructionsDir = '$dir/.github/instructions';
  final entries = (await env.listDir(instructionsDir)).valueOrNull ?? const [];
  final names = [
    for (final entry in entries)
      if (entry.kind == FileKind.file &&
          entry.name.endsWith('.instructions.md'))
        entry.name,
  ]..sort();
  for (final name in names) {
    final path = '$instructionsDir/$name';
    final content = (await env.readTextFile(path)).valueOrNull;
    if (content == null || content.trim().isEmpty) continue;
    dirFiles.add(
      ProjectContextFile(path: path, content: _copilotInstructions(content)),
    );
  }
  return dirFiles;
}

/// Renders one `.github/instructions/*.instructions.md` file: the body with
/// frontmatter stripped, prefixed with an `<!-- applies to: ... -->` marker
/// when `applyTo` scopes it (a YAML list or a comma-separated glob string).
/// No `applyTo` (or `applyTo: "**"`) includes the body unmarked.
/// `excludeAgent` is accepted but ignored (see the library doc).
String _copilotInstructions(String content) {
  final (frontmatter, body) = parseFrontmatterTyped(content);
  final applyTo = _applyToPatterns(frontmatter['applyTo']);
  if (applyTo.isEmpty || (applyTo.length == 1 && applyTo.single == '**')) {
    return body;
  }
  return '<!-- applies to: ${applyTo.join(', ')} -->\n$body';
}

/// Normalizes an `applyTo` value (YAML list or comma-separated string) into
/// a list of glob patterns.
List<String> _applyToPatterns(Object? applyTo) {
  final raw = switch (applyTo) {
    List() => [for (final item in applyTo) '$item'],
    String() => applyTo.split(','),
    _ => const <String>[],
  };
  return [
    for (final pattern in raw)
      if (pattern.trim().isNotEmpty) pattern.trim(),
  ];
}

/// Loads the user-level context file (e.g. `~/.fah/AGENTS.md`, pi's global
/// layer), or null when absent or empty.
Future<ProjectContextFile?> _loadUserFile(
  ExecutionEnv env,
  String? userFile,
) async {
  if (userFile == null) return null;
  final content = (await env.readTextFile(userFile)).valueOrNull;
  if (content != null && content.trim().isNotEmpty) {
    return ProjectContextFile(path: userFile, content: content);
  }
  return null;
}

String _parentOf(String dir) {
  if (dir == '/' || dir.isEmpty) return dir;
  final trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

/// Trims the merged list to [projectContextMaxBytes] allocating the budget
/// leaf-first (from the end of the list): a shallow file is truncated (or
/// dropped) before a deep one loses a byte.
List<ProjectContextFile> _applyBudget(List<ProjectContextFile> files) {
  const annotationOverhead = 40; // '<!-- From: path -->\n\n' estimate
  var remaining = projectContextMaxBytes;
  final keep = <ProjectContextFile?>[]..length = files.length;
  for (var i = files.length - 1; i >= 0; i--) {
    final file = files[i];
    final cost = file.content.length + annotationOverhead;
    if (cost <= remaining) {
      keep[i] = file;
      remaining -= cost;
    } else if (remaining > annotationOverhead + 256) {
      keep[i] = ProjectContextFile(
        path: file.path,
        content:
            '${file.content.substring(0, remaining - annotationOverhead)}\n'
            '… (truncated to the $projectContextMaxBytes-byte budget)',
      );
      remaining = 0;
    }
    // else: drop the shallow file entirely.
  }
  return [for (final file in keep) ?file];
}

/// Renders the context files as a system-prompt section (kimi's wrapper,
/// reduced): each file annotated with its source path, precedence note for
/// deeper-vs-shallower rules. Empty when nothing was discovered.
String formatProjectContext(List<ProjectContextFile> files) {
  if (files.isEmpty) return '';
  final buffer = StringBuffer()
    ..writeln('<project_context>')
    ..writeln()
    ..writeln('Project-specific instructions and guidelines:')
    ..writeln();
  for (final file in files) {
    buffer
      ..writeln('<!-- From: ${file.path} -->')
      ..writeln(file.content.trim())
      ..writeln();
  }
  buffer
    ..writeln('</project_context>')
    ..write(
      'When instructions in deeper files conflict with shallower ones, the '
      'deeper file takes precedence; user instructions given directly in '
      'the conversation take the highest precedence.',
    );
  return buffer.toString();
}
