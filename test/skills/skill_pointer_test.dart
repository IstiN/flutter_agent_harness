// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1444 UT-pointer (AC1 + security invariant): pointer resolution follows
// ONLY `builtin://skills/<name>/SKILL.md` targets naming the pointer's own
// skill; corrupt or foreign targets are refused loudly, and a missing
// pointer preserves the caller's original not-found outcome.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('validateSkillPointerTarget', () {
    test('accepts the seeder shape (single URI + trailing newline)', () {
      final reason = validateSkillPointerTarget(
        '/ws/.fah/skills/create-goal/SKILL.md',
        'builtin://skills/create-goal/SKILL.md\n',
      );
      expect(reason, isNull);
    });

    test('accepts a URI without the trailing newline', () {
      expect(
        validateSkillPointerTarget(
          '/ws/.fah/skills/js-apps/SKILL.md',
          'builtin://skills/js-apps/SKILL.md',
        ),
        isNull,
      );
    });

    test('refuses a foreign scheme (file://)', () {
      final reason = validateSkillPointerTarget(
        '/ws/.fah/skills/create-goal/SKILL.md',
        'file:///etc/passwd\n',
      );
      expect(reason, contains('builtin://skills/<name>/SKILL.md'));
    });

    test('refuses an unknown builtin skill name', () {
      final reason = validateSkillPointerTarget(
        '/ws/.fah/skills/nope/SKILL.md',
        'builtin://skills/nope/SKILL.md\n',
      );
      expect(reason, contains('not a compiled-in builtin skill'));
    });

    test('refuses a target pointing at a DIFFERENT skill directory', () {
      final reason = validateSkillPointerTarget(
        '/ws/.fah/skills/create-goal/SKILL.md',
        'builtin://skills/js-apps/SKILL.md\n',
      );
      expect(reason, contains('does not match the skill directory'));
    });

    test('refuses a corrupt multi-line body', () {
      expect(
        validateSkillPointerTarget(
          '/ws/.fah/skills/create-goal/SKILL.md',
          'builtin://skills/create-goal/SKILL.md\nrm -rf /\n',
        ),
        isNotNull,
      );
      expect(
        validateSkillPointerTarget('/ws/skills/x/SKILL.md', ''),
        isNotNull,
      );
    });

    test('refuses a non-SKILL.md resource inside the builtin namespace', () {
      expect(
        validateSkillPointerTarget(
          '/ws/.fah/skills/create-goal/SKILL.md',
          'builtin://skills/create-goal/extra.md\n',
        ),
        isNotNull,
      );
    });
  });

  group('followSkillPointer', () {
    test('resolves to the same bytes as the builtin URI (AC1)', () async {
      final result = await followSkillPointer(
        '/ws/.fah/skills/create-goal/SKILL.md',
        (pointerPath) async => 'builtin://skills/create-goal/SKILL.md\n',
      );
      expect(result, isA<SkillPointerResolved>());
      final resolved = result as SkillPointerResolved;
      expect(
        resolved.text,
        builtinSkillTextAt('builtin://skills/create-goal/SKILL.md'),
      );
      expect(resolved.skillName, 'create-goal');
    });

    test('every compiled-in builtin skill resolves through its pointer',
        () async {
      for (final skill in builtinSkills()) {
        final result = await followSkillPointer(
          '/ws/.fah/skills/${skill.name}/SKILL.md',
          (pointerPath) async => '${builtinSkillPath(skill.name)}\n',
        );
        expect(
          result,
          isA<SkillPointerResolved>(),
          reason: 'pointer for ${skill.name} must resolve',
        );
        expect(
          (result as SkillPointerResolved).text,
          skill.embeddedText,
          reason: '${skill.name} bytes must equal the builtin body',
        );
      }
    });

    test('a foreign-target pointer is refused loudly (E1)', () async {
      final result = await followSkillPointer(
        '/ws/.fah/skills/create-goal/SKILL.md',
        (pointerPath) async => 'file:///etc/passwd\n',
      );
      expect(result, isA<SkillPointerRefused>());
      expect(
        (result as SkillPointerRefused).reason,
        contains('builtin://skills/<name>/SKILL.md'),
      );
    });

    test('a missing pointer is absent, not an error', () async {
      final result = await followSkillPointer(
        '/ws/notes.txt',
        (pointerPath) async => null,
      );
      expect(result, isA<SkillPointerAbsent>());
    });

    test('a throwing pointer read degrades to absent', () async {
      final result = await followSkillPointer(
        '/ws/notes.txt',
        (pointerPath) async => throw StateError('fs exploded'),
      );
      expect(result, isA<SkillPointerAbsent>());
    });

    test('every builtin skill name is a single URI segment', () {
      for (final skill in builtinSkills()) {
        expect(skill.name.contains('/'), isFalse, reason: skill.name);
      }
    });
  });
}
