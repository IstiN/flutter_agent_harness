/// Agent skills: `SKILL.md` discovery with progressive disclosure (ported,
/// reduced, from pi's `core/skills.ts`, omp's `extensibility/skills.ts`, and
/// kimi-cli's `skill/__init__.py`).
///
/// A skill is a directory `<root>/<name>/SKILL.md` (canonical) or a flat
/// `<root>/<name>.md` file (lower priority on a name clash, kimi's pass 2).
/// Roots are scanned in scope order — project before user — with
/// first-name-wins (case-insensitive). Frontmatter fields: `name` (default:
/// directory/file stem) and `description` (fallback: first non-empty body
/// line, truncated; kimi's chain).
///
/// The model never receives skill bodies up front: [formatSkillsForPrompt]
/// renders only name+description+location and instructs the agent to load
/// the file with the `read` tool when the task matches (pi's
/// `<available_skills>` block). The CLI additionally supports explicit
/// invocation via `/skill:<name>` (kimi's slash runner).
library;

import 'package:yaml/yaml.dart' as yaml;

import '../env/execution_env.dart';

/// Where a skill was discovered (listing order in the prompt).
enum SkillScope { project, user }

/// One discovered skill (metadata only; the body stays on disk for
/// progressive disclosure via the `read` tool).
final class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.filePath,
    required this.scope,
  });

  /// The skill name (`name` frontmatter, else the directory/file stem).
  final String name;

  /// One-line description (`description` frontmatter, else first body line).
  final String description;

  /// Absolute path of the SKILL.md / .md file.
  final String filePath;

  /// Discovery scope.
  final SkillScope scope;
}

/// Parses `name`/`description` out of YAML frontmatter, falling back to the
/// file stem and the first non-empty body line (kimi's chain). Returns null
/// when the file cannot be read.
Future<Skill?> _loadSkillFile(
  ExecutionEnv env,
  String path,
  String fallbackName,
  SkillScope scope,
) async {
  final text = (await env.readTextFile(path)).valueOrNull;
  if (text == null) return null;
  final frontmatter = <String, String>{};
  var body = text;
  if (text.startsWith('---')) {
    final end = text.indexOf('\n---', 3);
    if (end > 0) {
      try {
        final doc = yaml.loadYaml(text.substring(3, end));
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
  final name = (frontmatter['name'] ?? fallbackName).trim();
  if (name.isEmpty) return null;
  var description = (frontmatter['description'] ?? '').trim();
  if (description.isEmpty) {
    description = body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (description.length > 240) {
      description = '${description.substring(0, 240)}…';
    }
  }
  if (description.isEmpty) description = 'No description provided.';
  return Skill(
    name: name,
    description: description,
    filePath: path,
    scope: scope,
  );
}

/// Scans one root directory for `<name>/SKILL.md` (canonical) and `<name>.md`
/// files (kimi's two passes; a bare top-level `SKILL.md` is ignored).
Future<List<Skill>> _scanRoot(
  ExecutionEnv env,
  String root,
  SkillScope scope,
) async {
  final entries = (await env.listDir(root)).valueOrNull;
  if (entries == null) return const [];
  final skills = <Skill>[];
  final seen = <String>{};

  // Pass 1: <name>/SKILL.md subdirectories (canonical).
  for (final entry in entries) {
    if (entry.kind != FileKind.directory || entry.name.startsWith('.')) {
      continue;
    }
    final path = '$root/${entry.name}/SKILL.md';
    if (!((await env.exists(path)).valueOrNull ?? false)) continue;
    final skill = await _loadSkillFile(env, path, entry.name, scope);
    if (skill != null && seen.add(skill.name.toLowerCase())) {
      skills.add(skill);
    }
  }

  // Pass 2: flat <name>.md files (lose on a name clash).
  for (final entry in entries) {
    if (entry.kind == FileKind.directory ||
        entry.name.startsWith('.') ||
        !entry.name.endsWith('.md') ||
        entry.name == 'SKILL.md') {
      continue;
    }
    final stem = entry.name.substring(0, entry.name.length - 3);
    final path = '$root/${entry.name}';
    final skill = await _loadSkillFile(env, path, stem, scope);
    if (skill != null && seen.add(skill.name.toLowerCase())) {
      skills.add(skill);
    }
  }
  return skills;
}

/// Discovers skills under [projectRoots] then [userRoots] (kimi's
/// precedence: project > user), first-name-wins case-insensitively. Missing
/// roots are silently skipped.
Future<List<Skill>> discoverSkills(
  ExecutionEnv env, {
  List<String> projectRoots = const [],
  List<String> userRoots = const [],
}) async {
  final skills = <Skill>[];
  final seen = <String>{};
  for (final (scope, roots) in [
    (SkillScope.project, projectRoots),
    (SkillScope.user, userRoots),
  ]) {
    for (final root in roots) {
      for (final skill in await _scanRoot(env, root, scope)) {
        if (seen.add(skill.name.toLowerCase())) skills.add(skill);
      }
    }
  }
  return skills;
}

/// The default skill roots for a host: `<cwd>/.fah/skills` +
/// `<cwd>/.agents/skills` (project) and, when a home directory exists,
/// `~/.fah/skills` + `~/.agents/skills` (user). Web/sandbox hosts pass
/// their sandbox cwd and no home (the sandbox FS carries project skills).
({List<String> projectRoots, List<String> userRoots}) defaultSkillRoots({
  required String cwd,
  String? homeDir,
}) {
  return (
    projectRoots: ['$cwd/.fah/skills', '$cwd/.agents/skills'],
    userRoots: homeDir == null
        ? const <String>[]
        : ['$homeDir/.fah/skills', '$homeDir/.agents/skills'],
  );
}

/// Renders the progressive-disclosure block for the system prompt (pi's
/// `<available_skills>`): metadata only — the agent loads a skill's file
/// with the `read` tool when the task matches its description. Empty when
/// there are no skills.
String formatSkillsForPrompt(List<Skill> skills) {
  if (skills.isEmpty) return '';
  String escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final buffer = StringBuffer()
    ..writeln(
      'The following skills provide specialized instructions for specific '
      'tasks.',
    )
    ..writeln(
      "Use the read tool to load a skill's file when the task matches its "
      'description.',
    )
    ..writeln(
      "When a skill file references a relative path, resolve it against the "
      'skill directory (parent of SKILL.md) and use that absolute path in '
      'tool commands.',
    )
    ..writeln()
    ..writeln('<available_skills>');
  for (final skill in skills) {
    buffer
      ..writeln('  <skill>')
      ..writeln('    <name>${escape(skill.name)}</name>')
      ..writeln('    <description>${escape(skill.description)}</description>')
      ..writeln('    <location>${escape(skill.filePath)}</location>')
      ..writeln('  </skill>');
  }
  buffer.write('</available_skills>');
  return buffer.toString();
}
