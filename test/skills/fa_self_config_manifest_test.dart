/// AC1 guard for the `self-settings` skill (issue #29): the shipped
/// `SKILL.md.pointer` resolves through the skills system, its frontmatter
/// parses into a valid [SkillManifest] with no unknown keys, and its
/// `allowed-tools` grants are plain tool names the per-turn approval gate
/// can honor.
///
/// Reads the repo's own `.fah/skills` root through the real filesystem env
/// (a VM-only test).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/skills/builtin_skills.dart';
import 'package:flutter_agent_harness/src/skills/skills.dart';
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;
final _skillPath = '$_repoRoot/.fah/skills/self-settings/SKILL.md';
final _skillPointerPath = '$_skillPath.pointer';

/// Tool ids the harness actually registers (built-ins the config skill may
/// be granted).
const _knownToolIds = {
  'read',
  'write',
  'edit',
  'ls',
  'bash',
  'web_search',
  'config',
  'lsp',
  'task',
  'ask',
  'checkpoint',
  'rewind',
  'inspect_image',
  'transcribe_audio',
};

void main() {
  setUpAll(() {
    expect(
      File(_skillPointerPath).existsSync(),
      isTrue,
      reason:
          'the shipped builtin pointer must live at '
          '.fah/skills/self-settings/SKILL.md.pointer',
    );
  });

  test('builtin is discovered and its repo pointer is materialized', () async {
    final env = LocalExecutionEnv(cwd: _repoRoot);
    final roots = defaultSkillRoots(cwd: _repoRoot);
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      builtins: builtinSkills(),
    );
    final matches = skills.where((s) => s.name == 'self-settings').toList();
    expect(
      matches,
      hasLength(1),
      reason: 'exactly one self-settings (no name clashes in-repo)',
    );
    final skill = matches.single;
    expect(skill.scope, SkillScope.builtin);
    expect(
      skill.source,
      SkillSource.builtin,
      reason: 'compiled-in first-party skill — no third-party consent needed',
    );
    expect(skill.filePath, 'builtin://skills/self-settings/SKILL.md');
  });

  test('frontmatter is valid with deliberate invocation flags', () async {
    final env = LocalExecutionEnv(cwd: _repoRoot);
    final roots = defaultSkillRoots(cwd: _repoRoot);
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      builtins: builtinSkills(),
    );
    final skill = skills.where((s) => s.name == 'self-settings').single;
    final manifest = skill.manifest;

    expect(manifest.description, isNotNull);
    expect(manifest.description, isNotEmpty);
    expect(manifest.whenToUse, isNotNull);
    // Deliberate: user-invocable AND model-invocable (both surfaces).
    expect(manifest.userInvocable, isTrue);
    expect(manifest.disableModelInvocation, isFalse);
    expect(manifest.argumentHint, isNotNull);
    // Unknown frontmatter keys or pattern tool grants would land here.
    expect(
      manifest.notes,
      isEmpty,
      reason: 'frontmatter must use only known keys and plain tool grants',
    );
    expect(
      manifest.contextFork,
      isFalse,
      reason: 'config edits run in the invoking turn, not a fork',
    );
  });

  test('allowed-tools are plain, real tool ids (grantable per turn)', () async {
    final env = LocalExecutionEnv(cwd: _repoRoot);
    final roots = defaultSkillRoots(cwd: _repoRoot);
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      builtins: builtinSkills(),
    );
    final manifest = skills
        .where((s) => s.name == 'self-settings')
        .single
        .manifest;

    expect(manifest.allowedTools, isNotEmpty);
    for (final tool in manifest.allowedTools) {
      expect(
        tool.contains('('),
        isFalse,
        reason:
            'pattern entries (Bash(...)) are never granted — '
            'only plain names take effect',
      );
      expect(
        _knownToolIds,
        contains(tool),
        reason: '"$tool" is not a registered tool id',
      );
    }
    expect(manifest.plainAllowedTools, manifest.allowedTools);
    // The workflow needs read+edit of config files and nothing exec-flavored
    // beyond bash for verification.
    expect(manifest.plainAllowedTools, containsAll(['read', 'edit', 'write']));
  });
}
