/// S5 drift guard (issue #29): every first-party skill under
/// `.fah/skills/` is mirrored byte-identically into the flutter app's
/// bundled assets (`flutter_app/assets/skills/`, seeded into sessions by
/// `AgentService._seedBundledSkills`) and listed in the app's pubspec
/// assets. The mirror is a BUILD ARTIFACT of the source skill: edit the
/// source, then re-copy it into the assets (never the reverse). Some
/// bundled skills are app-only (no `.fah/skills` source) - they are
/// exempt from the source comparison but still pinned to exist.
///
/// VM-only (reads files from disk).
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final skills = Directory('.fah/skills');
  final bundled = Directory('flutter_app/assets/skills');

  test('every first-party skill is bundled and listed in pubspec', () {
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
      expect(
        asset.existsSync(),
        isTrue,
        reason:
            'skill "$name" is not bundled for the app hosts - copy '
            '.fah/skills/$name/SKILL.md to '
            'flutter_app/assets/skills/$name/SKILL.md',
      );
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
}
