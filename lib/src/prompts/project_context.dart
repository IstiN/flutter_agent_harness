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
/// The merged-content budget (issue #1761) never cuts silently: a file
/// truncated to its head excerpt carries an explicit read-the-full-file
/// instruction, a file dropped entirely renders as a one-line tombstone,
/// and the loader reports both as user-facing notices
/// ([LoadedProjectContext.notices]).
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

import '../env/execution_env.dart';
import '../prompts/prompts.g.dart' show projectContextReadFullPrompt;
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

/// The `projectContext:` config section (issue #1761).
///
/// Tolerant parse: unknown keys and mistyped values produce [notes] and
/// defaults, never a boot failure — a typo must not kill a session.
final class ProjectContextConfig {
  /// Creates a configuration; see each field for its default.
  const ProjectContextConfig({
    this.maxBytes = projectContextMaxBytes,
    this.notes = const [],
  });

  /// The merged-content budget. `0` disables the project-context section
  /// entirely — no file reads at all (fast boot), an explicit opt-out
  /// distinct from "no files found".
  final int maxBytes;

  /// Tolerant-parse notes (unknown keys, mistyped scalars) surfaced at boot.
  final List<String> notes;

  /// Whether the section is switched off by config (`maxBytes: 0`).
  bool get isDisabled => maxBytes <= 0;

  /// The `projectContext:` yaml section, only the non-default value — the
  /// file stays minimal (defaults are never written). Empty at the default.
  String toYaml() => maxBytes == projectContextMaxBytes
      ? ''
      : 'projectContext:\n  maxBytes: $maxBytes\n';

  /// Parses the `projectContext:` yaml section. Tolerant (issue #1761
  /// AC5): numbers are accepted, mistyped scalars fall back to the
  /// default with a note, unknown keys are noted and ignored, and a
  /// negative value is treated as 0 (disabled). Never throws.
  factory ProjectContextConfig.fromYaml(Object? node) {
    if (node is! Map) return const ProjectContextConfig();
    final notes = <String>[];
    var maxBytes = projectContextMaxBytes;
    node.forEach((key, value) {
      switch ('$key') {
        case 'maxBytes':
          if (value is int) {
            maxBytes = value;
          } else if (value is num) {
            maxBytes = value.round();
          } else {
            notes.add('projectContext.maxBytes: not a number, default applied');
          }
        default:
          notes.add('projectContext.$key: unknown key (ignored)');
      }
    });
    if (maxBytes < 0) {
      notes.add('projectContext.maxBytes: negative, treated as 0 (disabled)');
      maxBytes = 0;
    }
    return ProjectContextConfig(
      maxBytes: maxBytes,
      notes: List.unmodifiable(notes),
    );
  }
}

/// One discovered context file whose content did not fit the merged
/// budget at all (issue #1761): it exists on disk but contributes
/// nothing to the prompt beyond a one-line tombstone.
final class ProjectContextDrop {
  const ProjectContextDrop({required this.path, required this.bytes});

  /// Absolute path of the dropped file.
  final String path;

  /// Original content length (Dart string length).
  final int bytes;
}

/// The project-context load outcome: the budgeted files plus what the
/// budget cut (issue #1761 — truncation is never silent).
final class LoadedProjectContext {
  const LoadedProjectContext({
    this.files = const [],
    this.dropped = const [],
    this.budgetBytes = projectContextMaxBytes,
  });

  /// Nothing discovered (or config-disabled): the no-section shape.
  static const empty = LoadedProjectContext();

  /// Kept files, farthest-first, closest (most specific) last. A file the
  /// budget truncated carries [ProjectContextFile.excerptBytes] +
  /// [ProjectContextFile.originalBytes] and its content is the head
  /// excerpt plus the read-the-full-file instruction.
  final List<ProjectContextFile> files;

  /// Files dropped entirely (a shallow file the leaf-first budget could
  /// not even excerpt). Rendered as one-line tombstones.
  final List<ProjectContextDrop> dropped;

  /// The budget that was applied (the config value or the default).
  final int budgetBytes;

  /// Whether anything was discovered (or dropped).
  bool get isEmpty => files.isEmpty && dropped.isEmpty;

  /// One user-facing boot line per truncated/dropped file (issue #1761
  /// AC2) — hosts print these dim; never silent.
  List<String> get notices => [
    for (final file in files)
      if (file.isTruncated)
        'project context truncated: ${_baseName(file.path)} '
            '${_sizeLabel(file.originalBytes!)} -> '
            '${_sizeLabel(file.excerptBytes!)} of the '
            '${_sizeLabel(budgetBytes)} budget '
            '(full file stays on disk)',
    for (final drop in dropped)
      'project context truncated: ${_baseName(drop.path)} '
          '${_sizeLabel(drop.bytes)} dropped '
          '(full file stays on disk)',
  ];
}

String _baseName(String path) => path.split('/').last;

/// Compact size label for boot lines: whole KBs (the issue's "512KB -> 28KB"
/// shape), MBs above a mebibyte, raw bytes below one kilobyte.
String _sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024) return '${bytes ~/ (1024 * 1024)}MB';
  if (bytes >= 1024) return '${bytes ~/ 1024}KB';
  return '${bytes}B';
}

/// Groups digits thousands-style for the model-facing size marker
/// (the issue's "512,340 bytes" shape).
String _groupDigits(int bytes) => '$bytes'.replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);

/// One discovered context file.
final class ProjectContextFile {
  const ProjectContextFile({
    required this.path,
    required this.content,
    this.excerptBytes,
    this.originalBytes,
  });

  /// Absolute path of the file.
  final String path;

  /// Verbatim file content; for a budget-truncated file the head excerpt
  /// followed by the read-the-full-file instruction (issue #1761).
  final String content;

  /// Length of the kept head excerpt when the budget truncated this file;
  /// null = kept whole. The fact, not arithmetic on rendered output —
  /// the size marker quotes it directly.
  final int? excerptBytes;

  /// Original content length when the budget truncated this file;
  /// null = kept whole.
  final int? originalBytes;

  /// Whether the merged budget cut this file down to a head excerpt.
  bool get isTruncated => originalBytes != null;
}

/// Loads every [projectContextFileNames] file walking from [cwd] up to the
/// git root (or the filesystem root). Returns files farthest-first, closest
/// (most specific) last. A [userFile] (e.g. `~/.fah/AGENTS.md`) is merged
/// first when present (pi's global layer). [maxBytes] is the merged budget
/// ([projectContextMaxBytes] by default); `<= 0` (the `maxBytes: 0`
/// opt-out) disables the section entirely — no file reads, an empty
/// [LoadedProjectContext] (issue #1761 AC5 fast boot).
Future<LoadedProjectContext> loadProjectContextFiles(
  ExecutionEnv env, {
  String? userFile,
  int maxBytes = projectContextMaxBytes,
}) async {
  if (maxBytes <= 0) return LoadedProjectContext.empty;
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
  return _applyBudget(found, maxBytes);
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

/// Trims the merged list to [maxBytes] allocating the budget leaf-first
/// (from the end of the list): a shallow file is truncated (or dropped)
/// before a deep one loses a byte. A truncated file keeps its head excerpt
/// plus the read-the-full-file instruction (issue #1761 AC1/AC3); a file
/// the budget cannot even excerpt becomes a [ProjectContextDrop] tombstone
/// instead of vanishing silently.
LoadedProjectContext _applyBudget(
  List<ProjectContextFile> files,
  int maxBytes,
) {
  const annotationOverhead = 40; // '<!-- From: path -->\n\n' estimate
  // A truncated block carries the read-the-full-file instruction plus the
  // extended From-marker (sizes) on top of the annotation — reserve for
  // them so the excerpt stays inside the budget (digits slop rides the
  // +64 below).
  final truncateReserve =
      annotationOverhead + projectContextReadFullPrompt.length + 64;
  var remaining = maxBytes;
  final keep = <ProjectContextFile?>[]..length = files.length;
  final dropped = <ProjectContextDrop>[];
  for (var i = files.length - 1; i >= 0; i--) {
    final file = files[i];
    final cost = file.content.length + annotationOverhead;
    if (cost <= remaining) {
      keep[i] = file;
      remaining -= cost;
    } else if (remaining > truncateReserve + 256) {
      final excerptBytes = remaining - truncateReserve;
      keep[i] = ProjectContextFile(
        path: file.path,
        content:
            '${file.content.substring(0, excerptBytes)}\n'
            '${projectContextReadFullPrompt.trim()}',
        excerptBytes: excerptBytes,
        originalBytes: file.content.length,
      );
      remaining = 0;
    } else {
      // Not even a meaningful excerpt fits: tombstone, zero content cost.
      dropped.insert(
        0,
        ProjectContextDrop(path: file.path, bytes: file.content.length),
      );
    }
  }
  return LoadedProjectContext(
    files: [for (final file in keep) ?file],
    dropped: dropped,
    budgetBytes: maxBytes,
  );
}

/// Renders the context files as a system-prompt section (kimi's wrapper,
/// reduced): each file annotated with its source path, precedence note for
/// deeper-vs-shallower rules. A dropped file renders as a one-line
/// tombstone naming the path on disk (issue #1761 AC1); a truncated file's
/// From-marker carries the original/excerpt sizes and the read-the-full-file
/// instruction follows its excerpt. Empty when nothing was discovered.
String formatProjectContext(LoadedProjectContext context) {
  if (context.isEmpty) return '';
  final buffer = StringBuffer()
    ..writeln('<project_context>')
    ..writeln()
    ..writeln('Project-specific instructions and guidelines:')
    ..writeln();
  for (final drop in context.dropped) {
    buffer.writeln(
      '<!-- ${drop.path} exists (${_sizeLabel(drop.bytes)}) but did not '
      'fit the ${_sizeLabel(context.budgetBytes)} budget — read it with '
      'the read tool if its rules apply -->',
    );
  }
  for (final file in context.files) {
    if (file.isTruncated) {
      buffer.writeln(
        '<!-- From: ${file.path} — ${_groupDigits(file.originalBytes!)} '
        'bytes, only the first ${_groupDigits(file.excerptBytes!)} shown '
        '(${_sizeLabel(context.budgetBytes)} merged budget) -->',
      );
      buffer
        ..writeln(file.content.trim())
        ..writeln();
    } else {
      buffer
        ..writeln('<!-- From: ${file.path} -->')
        ..writeln(file.content.trim())
        ..writeln();
    }
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
