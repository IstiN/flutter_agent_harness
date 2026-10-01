/// Built-in agent skills shipped inside the fa package itself (issue #1151).
///
/// The SKILL.md sources live under `prompts/skills/<name>/SKILL.md` (same
/// layout as every other skill root; "prompts live outside Dart code") and
/// are compiled into `builtinSkillFiles` by `scripts/gen_prompts.dart` —
/// pure-Dart package data, no `dart:io`, so every host (CLI, macOS app,
/// iOS, Android, web) serves them without filesystem access.
///
/// Discovery treats them as the LOWEST-precedence source: a project, user,
/// or granted third-party skill of the same name shadows the built-in
/// (see [discoverSkills]). The skills-access consent never gates them —
/// they are first-party and ship with fa.
library;

import '../prompts/prompts.g.dart' show builtinSkillFiles;
import '../utils/frontmatter_parser.dart';
import 'skills.dart';

export 'skills.dart' show Skill;

/// Prefix of a built-in skill's virtual [Skill.filePath]. The `read` tool
/// serves these paths from the embedded copy (see `builtinSkillTextAt`), so
/// model-initiated progressive disclosure works on every host.
const builtinSkillPathPrefix = 'builtin://skills/';

/// The virtual SKILL.md path of the built-in skill [name].
String builtinSkillPath(String name) => '$builtinSkillPathPrefix$name/SKILL.md';

/// The compiled-in built-in skills, in name order, parsed exactly like an
/// on-disk SKILL.md (frontmatter → [SkillManifest]). Empty until
/// `scripts/gen_prompts.dart` has run — hosts merge them into discovery
/// last so real skills always win a name clash.
List<Skill> builtinSkills() {
  final skills = <Skill>[];
  for (final entry in builtinSkillFiles.entries) {
    final (frontmatter, body) = parseFrontmatterTyped(entry.value);
    final manifest = SkillManifest.fromFrontmatter(
      frontmatter,
      skillName: entry.key,
    );
    final name = ('${frontmatter['name'] ?? entry.key}').trim();
    if (name.isEmpty) continue;
    skills.add(
      Skill(
        name: name,
        description: _builtinSkillDescription(manifest, body),
        filePath: builtinSkillPath(name),
        scope: SkillScope.builtin,
        source: SkillSource.builtin,
        manifest: manifest,
        embeddedText: entry.value,
      ),
    );
  }
  return skills;
}

/// Same derivation as skills.dart's `_skillDescription`.
String _builtinSkillDescription(SkillManifest manifest, String body) {
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

/// The built-in skill text at [path] (`builtin://skills/<name>/SKILL.md`),
/// or null when [path] is not a built-in skill path. Read-tool hosts call
/// this before touching the filesystem.
String? builtinSkillTextAt(String path) {
  if (!path.startsWith(builtinSkillPathPrefix)) return null;
  final rest = path.substring(builtinSkillPathPrefix.length);
  final slash = rest.indexOf('/');
  if (slash < 0 || rest.substring(slash) != '/SKILL.md') return null;
  final name = rest.substring(0, slash);
  for (final skill in builtinSkills()) {
    if (skill.name == name) return skill.embeddedText;
  }
  return null;
}
