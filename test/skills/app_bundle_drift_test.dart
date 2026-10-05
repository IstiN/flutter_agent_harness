/// S5 drift guard (issue #29, reworked by #1151): every first-party skill
/// under `.fah/skills/` reaches app sessions EITHER as a package built-in
/// (embedded by `scripts/gen_prompts.dart` into `builtinSkillFiles`) OR —
/// for app-only skills with no package embedding — as a bundled asset
/// (`flutter_app/assets/skills/`, listed in the app's pubspec and seeded
/// into sessions by `AgentService._seedBundledSkills`). Skills that are
/// both bundled and embedded are forbidden: the seeded project copy would
/// shadow the built-in with a duplicate listing.
///
/// VM-only (reads files from disk).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final skills = Directory('.fah/skills');
  final bundled = Directory('flutter_app/assets/skills');
  final embedded = builtinSkills().map((s) => s.name).toSet();

  test('every first-party skill ships as a builtin or a bundled app asset', () {
    expect(skills.existsSync(), isTrue, reason: '.fah/skills missing');
    final names =
        skills
            .listSync()
            .whereType<Directory>()
            .map((d) => d.uri.pathSegments.reversed.toList()[1])
            .toList()
          ..sort();
    expect(names, isNotEmpty);

    final pubspec = File('flutter_app/pubspec.yaml').readAsStringSync();
    for (final name in names) {
      final asset = File('flutter_app/assets/skills/$name/SKILL.md');
      if (embedded.contains(name)) {
        // #1151: shipped inside the core package - invocable on every
        // surface. The .fah/skills copy stays as a project override
        // (non-goal to migrate), but a bundled app copy would shadow the
        // builtin with a duplicate listing.
        expect(
          asset.existsSync(),
          isFalse,
          reason:
              'skill "$name" is embedded as a package builtin; the '
              'bundled app copy shadows it with a duplicate listing - '
              'delete flutter_app/assets/skills/$name/',
        );
        expect(
          pubspec.contains('assets/skills/$name/'),
          isFalse,
          reason:
              'skill "$name" is embedded as a package builtin but still '
              'listed in flutter_app/pubspec.yaml assets',
        );
        continue;
      }
      // Not embedded: project override. If the app bundles it anyway,
      // the old mirror rules apply; otherwise project-only is fine.
      if (!asset.existsSync()) continue;
      expect(
        pubspec,
        contains('assets/skills/$name/SKILL.md'),
        reason:
            'skill "$name" is bundled but not listed in '
            'flutter_app/pubspec.yaml assets',
      );
    }
  });

  test('bundled SKILL.md copies are byte-identical to the source skill', () {
    if (!bundled.existsSync()) return; // gh-1164: no bundled skills left
    for (final dir in bundled.listSync().whereType<Directory>()) {
      final name = dir.uri.pathSegments.reversed.toList()[1];
      final source = File('.fah/skills/$name/SKILL.md');
      final copy = File('flutter_app/assets/skills/$name/SKILL.md');
      if (!source.existsSync()) continue; // app-only skill, no source pin
      expect(
        copy.readAsStringSync(),
        source.readAsStringSync(),
        reason:
            'flutter_app/assets/skills/$name/SKILL.md drifted from '
            '.fah/skills/$name/SKILL.md - re-copy the source skill '
            '(the source of truth is .fah/skills/)',
      );
    }
  });

  test('AgentService._seedBundledSkills no longer seeds any bundled skill', () {
    // gh-1164 Part A: the last bundled skill (js-apps) moved into the
    // package builtins, so the seeder has nothing left to seed — it only
    // retires the stale seeded copies. Guard the retirement: the source
    // must not grow a bundled-seeding map again (rootBundle.loadString
    // of an assets/skills path), and any skill re-added under
    // flutter_app/assets/skills/ must come back through the drift rules
    // in the tests above.
    final source = File(
      'flutter_app/lib/services/agent_service_skills.dart',
    ).readAsStringSync();
    final decl = source.indexOf('Future<void> _seedBundledSkills');
    expect(decl, greaterThanOrEqualTo(0), reason: 'seeder missing');
    final bodyEnd = source.indexOf('\n}\n', decl);
    expect(bodyEnd, greaterThan(decl), reason: 'seeder body missing');
    final body = source.substring(decl, bodyEnd);
    expect(
      body,
      isNot(contains('rootBundle.loadString')),
      reason:
          '_seedBundledSkills seeds from the asset bundle again - the '
          'bundled-skill machinery was retired by gh-1164 Part A',
    );
    expect(
      body,
      isNot(contains('assets/skills')),
      reason:
          '_seedBundledSkills references assets/skills again - bundled '
          'skills were retired by gh-1164 Part A',
    );
  });
}
