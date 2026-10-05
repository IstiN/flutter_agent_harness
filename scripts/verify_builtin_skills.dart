/// Release gate for built-in skill PACKAGED CONTENT (gh-1275 AC3).
///
/// 1.0.512 shipped the apps with the skill DIRECTORY STRUCTURE present but
/// the SKILL.md CONTENT missing (#1151's app-side seeder read bundled
/// assets the packaging glob never packed — the #1227/#1272 asset-diet
/// class), and nothing caught it because every existing guard asserted
/// presence, never byte content. The packaging mechanism is compiled-in
/// Dart now (gh-1164: `scripts/gen_prompts.dart` embeds every
/// `prompts/skills/<name>/SKILL.md` into `builtinSkillFiles`), so this
/// gate checks the exact bytes every host (iOS, macOS, Android, web,
/// CLI) compiles into its artifact:
///
/// ```sh
/// dart run scripts/verify_builtin_skills.dart   # exit 1 + named verdicts
/// ```
///
/// Wired fail-fast into the app release workflows (build-mobile.yml,
/// build-macos.yml, pages.yml) BEFORE any build minute is spent
/// (gh-798's "Assert TestFlight version floor" pattern); the same
/// checkers run on every PR via
/// `test/skills/builtin_skill_packaging_guard_test.dart`
/// (gh-798 selftest pattern: the gate cannot rot silently).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show builtinSkillFiles;

/// Byte floor for a shipped SKILL.md (gh-1275 AC3: "each built-in skill
/// dir contains a non-empty SKILL.md (byte size > some floor)"). The
/// smallest built-in today is create-goal at ~8.3 KB — the floor only
/// has to catch the incident class (empty / whitespace / frontmatter-only
/// stubs), never to police size.
const builtinSkillMinBytes = 1024;

/// Content verdicts for one name → SKILL.md-text map (the packaged
/// artifact's built-in skill table). An empty list means every shipped
/// skill carries usable content. Pure and synchronous so the tests can
/// drive it with incident-shaped fixtures.
List<String> builtinSkillContentViolations(
  Map<String, String> builtinFiles, {
  int minBytes = builtinSkillMinBytes,
}) {
  final violations = <String>[];
  if (builtinFiles.isEmpty) {
    violations.add(
      'packaged artifact ships NO built-in skills at all '
      '(builtinSkillFiles is empty — gen_prompts never ran?)',
    );
  }
  final entries = builtinFiles.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in entries) {
    final bytes = utf8.encode(entry.value).length;
    if (entry.value.trim().isEmpty) {
      violations.add(
        'built-in skill "${entry.key}": SKILL.md ships EMPTY '
        '(0 bytes of content — the gh-1275 incident shape)',
      );
    } else if (bytes < minBytes) {
      violations.add(
        'built-in skill "${entry.key}": SKILL.md is $bytes bytes, below '
        'the $minBytes-byte floor — a frontmatter-only stub is not a '
        'usable skill',
      );
    }
  }
  return violations;
}

/// Source-side verdicts for the on-disk tree at [repoRoot]: every
/// `prompts/skills/<name>/` must carry a non-empty SKILL.md at or above
/// the floor. A directory WITHOUT a SKILL.md is exactly what iOS shipped
/// in 1.0.512 — the structure/content split the release gate exists for.
Future<List<String>> builtinSkillSourceViolations(
  String repoRoot, {
  int minBytes = builtinSkillMinBytes,
}) async {
  final dir = Directory('$repoRoot/prompts/skills');
  if (!dir.existsSync()) {
    return ['prompts/skills/ is missing entirely — no built-in skill sources'];
  }
  final violations = <String>[];
  final names =
      dir.listSync().whereType<Directory>().map(
        (d) => d.uri.pathSegments.reversed.toList()[1],
      ).toList()
        ..sort();
  if (names.isEmpty) {
    violations.add(
      'prompts/skills/ has no skill directories — the built-in skill '
      'set shipped empty',
    );
  }
  for (final name in names) {
    final file = File('${dir.path}/$name/SKILL.md');
    if (!file.existsSync()) {
      violations.add(
        'built-in skill "$name": prompts/skills/$name/ exists WITHOUT '
        'SKILL.md — directory structure without content (gh-1275)',
      );
      continue;
    }
    final bytes = file.lengthSync();
    if (bytes == 0 || (await file.readAsString()).trim().isEmpty) {
      violations.add(
        'built-in skill "$name": prompts/skills/$name/SKILL.md ships '
        'EMPTY — directory structure without content (gh-1275)',
      );
    } else if (bytes < minBytes) {
      violations.add(
        'built-in skill "$name": prompts/skills/$name/SKILL.md is '
        '$bytes bytes, below the $minBytes-byte floor — a '
        'frontmatter-only stub is not a usable skill',
      );
    }
  }
  return violations;
}

/// Parity verdicts between the on-disk source set and the packaged
/// (compiled) set: the artifact must embed EXACTLY the skills the sources
/// declare — a stale generated file shipping fewer skills than sources is
/// the "packaging glob misses entries" half of the incident class. (Drift
/// the other way is caught by `test/prompts/prompts_sync_test.dart`.)
List<String> builtinSkillNameParityViolations(
  Set<String> sourceNames,
  Set<String> packagedNames,
) {
  final missing = sourceNames.difference(packagedNames).toList()..sort();
  final extra = packagedNames.difference(sourceNames).toList()..sort();
  return [
    if (missing.isNotEmpty)
      'packaged artifact is missing built-in skills declared on disk: '
          '${missing.join(', ')} — run `dart run scripts/gen_prompts.dart`',
    if (extra.isNotEmpty)
      'packaged artifact embeds built-in skills with no on-disk source: '
          '${extra.join(', ')} — remove the generated entry or restore '
          'the source directory',
  ];
}

/// The full gh-1275 AC3 gate: sources, packaged content, and parity.
Future<List<String>> verifyBuiltinSkills({String repoRoot = '.'}) async {
  final skillsDir = Directory('$repoRoot/prompts/skills');
  final sourceNames = <String>{
    if (skillsDir.existsSync())
      ...skillsDir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.reversed.toList()[1]),
  };
  return [
    ...await builtinSkillSourceViolations(repoRoot),
    ...builtinSkillContentViolations(builtinSkillFiles),
    ...builtinSkillNameParityViolations(
      sourceNames,
      builtinSkillFiles.keys.toSet(),
    ),
  ];
}

Future<void> main(List<String> args) async {
  final repoRoot = args.isNotEmpty ? args.first : '.';
  final violations = await verifyBuiltinSkills(repoRoot: repoRoot);
  if (violations.isEmpty) {
    print(
      '✅ built-in skills packaged: ${builtinSkillFiles.length} skills, '
      'every SKILL.md ≥ $builtinSkillMinBytes bytes (gh-1275 AC3)',
    );
    return;
  }
  stderr.writeln(
    '::error::built-in skill packaging guard failed (gh-1275 AC3):',
  );
  for (final violation in violations) {
    stderr.writeln('::error::  - $violation');
  }
  exit(1);
}
