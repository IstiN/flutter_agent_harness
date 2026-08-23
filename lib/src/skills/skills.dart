/// Agent skills: multi-format `SKILL.md` discovery with progressive
/// disclosure.
///
/// A skill is a directory `<root>/<name>/SKILL.md` (canonical; Agent Skills
/// open standard shared by Claude Code, GitHub Copilot and OpenAI Codex) or
/// a flat `<root>/<name>.md` file (lower priority on a name clash).
/// Additionally, Claude's command files (`<root>/.claude/commands/<name>.md`)
/// are discovered as invocable skills.
///
/// Roots carry a [SkillSource] so the host can tell first-party locations
/// (`.fah/skills`, `.agents/skills` — always read) from third-party ones
/// (`.claude/`, `.github/`, `.codex/` + their `~/` mirrors — read only after
/// the user granted access, see `skills_access.dart`).
///
/// Frontmatter is parsed into a typed [SkillManifest]; unknown keys never
/// break loading. The model never receives skill bodies up front:
/// [formatSkillsForPrompt] renders only name+description+location and
/// instructs the agent to load the file with the `read` tool when the task
/// matches. The CLI additionally supports explicit invocation via
/// `/skill:<name>` or `/name`.
library;

import '../utils/frontmatter_parser.dart';
import '../utils/glob_match.dart';
import '../env/execution_env.dart';
import 'skill_manifest.dart';

export 'skill_manifest.dart';
export 'skills_access.dart';

/// Where a skill was discovered (listing order in the prompt).
enum SkillScope { project, user }

/// Which tool's directory layout the skill came from. First-party roots
/// (`.fah`, `.agents`) are always readable; third-party roots
/// (`.claude`/`.github`/`.codex`) are gated by the user's skills-access
/// consent (see `skills_access.dart`).
enum SkillSource { fah, agents, claude, copilot, codex }

/// Whether [source] is a third-party directory that requires the user's
/// skills-access consent before reading.
bool skillSourceIsThirdParty(SkillSource source) {
  return switch (source) {
    SkillSource.fah || SkillSource.agents => false,
    SkillSource.claude || SkillSource.copilot || SkillSource.codex => true,
  };
}

/// One discovery root: a directory to scan plus its [SkillSource].
/// [commandDir] roots (Claude's `.claude/commands/`) contain flat
/// `<name>.md` command files only — no `<name>/SKILL.md` pass.
final class SkillRoot {
  const SkillRoot(this.path, this.source, {this.commandDir = false});

  final String path;
  final SkillSource source;
  final bool commandDir;

  /// Whether reading this root requires skills-access consent.
  bool get isThirdParty => skillSourceIsThirdParty(source);
}

/// One discovered skill (metadata + parsed manifest; the body stays on disk
/// for progressive disclosure via the `read` tool / skill renderer).
final class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.filePath,
    required this.scope,
    required this.source,
    this.manifest = SkillManifest.empty,
  });

  /// The skill name (`name` frontmatter, else the directory/file stem).
  final String name;

  /// One-line description (`description` frontmatter + `when_to_use`, else
  /// the first non-empty body line).
  final String description;

  /// Absolute path of the SKILL.md / .md file.
  final String filePath;

  /// The skill's directory (parent of [filePath]).
  String get directory => filePath.substring(0, filePath.lastIndexOf('/'));

  /// Discovery scope.
  final SkillScope scope;

  /// Which tool's layout this skill was found in.
  final SkillSource source;

  /// The typed frontmatter ([SkillManifest.empty] when absent).
  final SkillManifest manifest;

  /// Claude's `disable-model-invocation`: hidden from the model catalog,
  /// invocable by the user only.
  bool get modelInvocable => !manifest.disableModelInvocation;

  /// Claude's `user-invocable: false`: loadable by the model only.
  bool get userInvocable => manifest.userInvocable;

  /// Path-gated skills ([SkillManifest.paths] / Copilot's `applyTo`) enter
  /// the model catalog only when one of [touchedPaths] matches a glob.
  /// Skills without path patterns always match.
  bool matchesTouchedPaths(Iterable<String> touchedPaths, {String? cwd}) {
    final patterns = [...manifest.paths, ...manifest.applyTo];
    if (patterns.isEmpty) return true;
    for (var path in touchedPaths) {
      final candidates = [
        path,
        if (cwd != null && path.startsWith('$cwd/'))
          path.substring(cwd.length + 1),
      ];
      for (final pattern in patterns) {
        if (candidates.any((c) => globMatches(pattern, c))) return true;
      }
    }
    return false;
  }
}

/// Loads one skill file. Returns null when the file cannot be read.
Future<Skill?> _loadSkillFile(
  ExecutionEnv env,
  String path,
  String fallbackName,
  SkillScope scope,
  SkillSource source,
) async {
  final text = (await env.readTextFile(path)).valueOrNull;
  if (text == null) return null;
  final (frontmatter, body) = parseFrontmatterTyped(text);
  final manifest = SkillManifest.fromFrontmatter(
    frontmatter,
    skillName: fallbackName,
  );
  final name = ('${frontmatter['name'] ?? fallbackName}').trim();
  if (name.isEmpty) return null;
  return Skill(
    name: name,
    description: _skillDescription(manifest, body),
    filePath: path,
    scope: scope,
    source: source,
    manifest: manifest,
  );
}

/// Derives the one-line description: the manifest's `description` (with
/// `when_to_use` appended), else the first non-empty body line (truncated to
/// 240 chars), else a placeholder.
String _skillDescription(SkillManifest manifest, String body) {
  var description = (manifest.catalogDescription ?? '').trim();
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
  return description;
}

/// Scans one root directory. Directory roots find `<name>/SKILL.md`
/// subdirectories (canonical) plus flat `<name>.md` files (which lose a name
/// clash); [SkillRoot.commandDir] roots find flat files only.
Future<List<Skill>> _scanRoot(
  ExecutionEnv env,
  SkillRoot root,
  SkillScope scope,
) async {
  final entries = (await env.listDir(root.path)).valueOrNull;
  if (entries == null) return const [];
  final seen = <String>{};
  return [
    if (!root.commandDir)
      ...await _scanSkillDirs(env, root, scope, entries, seen),
    ...await _scanFlatFiles(env, root, scope, entries, seen),
  ];
}

/// Pass 1 of [_scanRoot]: `<name>/SKILL.md` subdirectories (canonical).
Future<List<Skill>> _scanSkillDirs(
  ExecutionEnv env,
  SkillRoot root,
  SkillScope scope,
  List<FileInfo> entries,
  Set<String> seen,
) async {
  final skills = <Skill>[];
  for (final entry in entries) {
    if (entry.kind != FileKind.directory || entry.name.startsWith('.')) {
      continue;
    }
    final path = '${root.path}/${entry.name}/SKILL.md';
    if (!((await env.exists(path)).valueOrNull ?? false)) continue;
    final skill = await _loadSkillFile(
      env,
      path,
      entry.name,
      scope,
      root.source,
    );
    if (skill != null && seen.add(skill.name.toLowerCase())) {
      skills.add(skill);
    }
  }
  return skills;
}

/// Whether [entry] is a flat `<name>.md` skill file (a bare top-level
/// `SKILL.md` is ignored).
bool _isFlatSkillFile(FileInfo entry) {
  return entry.kind != FileKind.directory &&
      !entry.name.startsWith('.') &&
      entry.name.endsWith('.md') &&
      entry.name != 'SKILL.md';
}

/// Pass 2 of [_scanRoot]: flat `<name>.md` files (lose on a name clash).
Future<List<Skill>> _scanFlatFiles(
  ExecutionEnv env,
  SkillRoot root,
  SkillScope scope,
  List<FileInfo> entries,
  Set<String> seen,
) async {
  final skills = <Skill>[];
  for (final entry in entries) {
    if (!_isFlatSkillFile(entry)) continue;
    final stem = entry.name.substring(0, entry.name.length - 3);
    final path = '${root.path}/${entry.name}';
    final skill = await _loadSkillFile(env, path, stem, scope, root.source);
    if (skill != null && seen.add(skill.name.toLowerCase())) {
      skills.add(skill);
    }
  }
  return skills;
}

/// Discovers skills under [projectRoots] then [userRoots] (project wins on a
/// name clash, first-name-wins case-insensitively). Roots whose source is
/// not in [allowedSources] (defaults: everything) are skipped — hosts pass
/// the first-party set when the user has not granted third-party skills
/// access. Missing roots are silently skipped.
Future<List<Skill>> discoverSkills(
  ExecutionEnv env, {
  List<SkillRoot> projectRoots = const [],
  List<SkillRoot> userRoots = const [],
  Set<SkillSource>? allowedSources,
}) {
  bool allowed(SkillRoot root) =>
      allowedSources == null || allowedSources.contains(root.source);
  final skills = <Skill>[];
  final seen = <String>{};
  Future<void> scan(SkillScope scope, List<SkillRoot> roots) async {
    for (final root in roots.where(allowed)) {
      for (final skill in await _scanRoot(env, root, scope)) {
        if (seen.add(skill.name.toLowerCase())) skills.add(skill);
      }
    }
  }

  return () async {
    await scan(SkillScope.project, projectRoots);
    await scan(SkillScope.user, userRoots);
    return skills;
  }();
}

/// The default skill roots for a host.
///
/// Project: `.fah/skills` + `.agents/skills` (first-party), then the
/// third-party Agent Skills locations `.claude/skills`, `.github/skills`,
/// `.codex/skills`, plus Claude's `.claude/commands` (flat command files).
/// User (when a home directory exists): the same set under `~`, plus
/// `~/.copilot/skills` and `~/.claude/commands`. Web/sandbox hosts pass
/// their sandbox cwd and no home (the sandbox FS carries project skills).
({List<SkillRoot> projectRoots, List<SkillRoot> userRoots}) defaultSkillRoots({
  required String cwd,
  String? homeDir,
}) {
  return (
    projectRoots: [
      SkillRoot('$cwd/.fah/skills', SkillSource.fah),
      SkillRoot('$cwd/.agents/skills', SkillSource.agents),
      SkillRoot('$cwd/.claude/skills', SkillSource.claude),
      SkillRoot('$cwd/.github/skills', SkillSource.copilot),
      SkillRoot('$cwd/.codex/skills', SkillSource.codex),
      SkillRoot('$cwd/.claude/commands', SkillSource.claude, commandDir: true),
    ],
    userRoots: homeDir == null
        ? const <SkillRoot>[]
        : [
            SkillRoot('$homeDir/.fah/skills', SkillSource.fah),
            SkillRoot('$homeDir/.agents/skills', SkillSource.agents),
            SkillRoot('$homeDir/.claude/skills', SkillSource.claude),
            SkillRoot('$homeDir/.copilot/skills', SkillSource.copilot),
            SkillRoot('$homeDir/.codex/skills', SkillSource.codex),
            SkillRoot(
              '$homeDir/.claude/commands',
              SkillSource.claude,
              commandDir: true,
            ),
          ],
  );
}

/// Renders the progressive-disclosure block for the system prompt:
/// metadata only — the agent loads a skill's file with the `read` tool when
/// the task matches its description. Empty when there are no skills.
///
/// [forModel] applies Claude's invocation flags: `disable-model-invocation`
/// skills are excluded, and path-gated skills (`paths:` / `applyTo:`) enter
/// only when [touchedPaths] matches one of their globs.
String formatSkillsForPrompt(
  List<Skill> skills, {
  bool forModel = true,
  Iterable<String> touchedPaths = const [],
  String? cwd,
}) {
  final listed = forModel
      ? skills
            .where(
              (s) =>
                  s.modelInvocable &&
                  s.matchesTouchedPaths(touchedPaths, cwd: cwd),
            )
            .toList()
      : skills;
  if (listed.isEmpty) return '';
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
  for (final skill in listed) {
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
