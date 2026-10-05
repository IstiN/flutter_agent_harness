/// gh-1275 AC3 — the release gate for built-in skill PACKAGED CONTENT
/// (`scripts/verify_builtin_skills.dart`, wired into the app release
/// workflows) must catch the 1.0.512 incident class — the skill DIRECTORY
/// STRUCTURE shipped while the SKILL.md CONTENT never reached the bundle —
/// and the current tree must pass it. Selftest pattern of gh-798: the gate
/// logic lives in the script, these fixtures prove it cannot rot into a
/// no-op without failing here on every PR.
///
/// VM-only (reads the on-disk sources under `prompts/skills/`).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show builtinSkillFiles;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../scripts/verify_builtin_skills.dart' as guard;

void main() {
  group('builtinSkillContentViolations — the packaged-artifact check', () {
    test('flags an EMPTY SKILL.md — the exact shipped 1.0.512 shape', () {
      final violations = guard.builtinSkillContentViolations({
        'create-goal': '',
      });
      expect(violations, hasLength(1));
      expect(violations.single, contains('create-goal'));
      expect(violations.single, contains('EMPTY'));
    });

    test('flags whitespace-only and frontmatter-only stubs', () {
      final violations = guard.builtinSkillContentViolations({
        'whitespace': '   \n \t\n',
        // Frontmatter present, body absent: "non-empty" by byte count of
        // the header alone, useless as a skill — the floor exists for it.
        'frontmatter-only': '---\nname: x\ndescription: y\n---\n',
      });
      expect(violations, hasLength(2));
      expect(
        violations,
        contains(contains('whitespace')),
      );
      expect(
        violations,
        contains(contains('frontmatter-only')),
      );
    });

    test('multi-item map: reports only the broken skills', () {
      final violations = guard.builtinSkillContentViolations({
        'good': 'x' * 2048,
        'also-good': 'y' * 4096,
        'broken': '',
      });
      expect(violations, hasLength(1));
      expect(violations.single, contains('broken'));
    });

    test('flags a completely empty artifact (generator never ran)', () {
      final violations = guard.builtinSkillContentViolations(const {});
      expect(violations, hasLength(1));
      expect(violations.single, contains('NO built-in skills'));
    });

    test('passes the REAL packaged artifact (compiled builtinSkillFiles)', () {
      expect(
        guard.builtinSkillContentViolations(builtinSkillFiles),
        isEmpty,
        reason:
            'the shipped builtinSkillFiles map carries an under-floor or '
            'empty SKILL.md — this is the gh-1275 incident class',
      );
    });
  });

  group('builtinSkillMdByteViolations — the single-read byte-level core', () {
    test('flags empty and whitespace-only bytes', () {
      for (final content in [
        utf8.encode(''),
        utf8.encode('   \n \t\n'),
      ]) {
        final violations = guard.builtinSkillMdByteViolations(
          'some-skill',
          content,
        );
        expect(violations, hasLength(1));
        expect(violations.single, contains('some-skill'));
        expect(violations.single, contains('EMPTY'));
      }
    });

    test('flags bytes below the floor, reporting the inspected count', () {
      final violations = guard.builtinSkillMdByteViolations(
        'stub-skill',
        utf8.encode('---\nname: x\ndescription: y\n---\n'),
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('stub-skill'));
      expect(violations.single, contains('below'));
    });

    test('passes content at or above the floor', () {
      expect(
        guard.builtinSkillMdByteViolations('full', utf8.encode('x' * 2048)),
        isEmpty,
      );
    });

    test('labels the verdict with the source path when given', () {
      final violations = guard.builtinSkillMdByteViolations(
        'some-skill',
        utf8.encode(''),
        path: 'prompts/skills/some-skill/SKILL.md',
      );
      expect(violations.single, contains('prompts/skills/some-skill/SKILL.md'));
    });
  });

  group('builtinSkillSourceViolations — the on-disk source check', () {
    test('current tree passes: every prompts/skills/<name>/SKILL.md is full', () {
      expect(
        guard.builtinSkillSourceViolations('.'),
        completion(isEmpty),
        reason:
            'a prompts/skills/<name>/SKILL.md source is missing or under '
            'the byte floor',
      );
    });

    test(
      'fixture (RED of #1275): directory structure WITHOUT the SKILL.md '
      'content fails — one verdict per hollow skill',
      () async {
        final tmp = await Directory.systemTemp.createTemp(
          'builtin_skill_guard',
        );
        try {
          // The 1.0.512 iOS shape: the dirs exist; the content does not.
          await Directory(
            '${tmp.path}/prompts/skills/create-goal',
          ).create(recursive: true);
          await File(
            '${tmp.path}/prompts/skills/create-goal/SKILL.md',
          ).writeAsString('');
          await Directory(
            '${tmp.path}/prompts/skills/js-apps',
          ).create(recursive: true); // no SKILL.md at all
          await Directory(
            '${tmp.path}/prompts/skills/self-settings',
          ).create(recursive: true);
          await File(
            '${tmp.path}/prompts/skills/self-settings/SKILL.md',
          ).writeAsString('z' * 2048);

          final violations = await guard.builtinSkillSourceViolations(
            tmp.path,
          );
          expect(violations, hasLength(2));
          expect(violations[0], contains('create-goal'));
          expect(violations[0], contains('EMPTY'));
          expect(violations[1], contains('js-apps'));
          expect(violations[1], contains('WITHOUT'));
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );

    test(
      'fixture: a dotted skill dir name survives the source scan intact '
      '(basename, not the uri.pathSegments idiom)',
      () async {
        final tmp = await Directory.systemTemp.createTemp(
          'builtin_skill_guard',
        );
        try {
          await Directory(
            '${tmp.path}/prompts/skills/dotted.name',
          ).create(recursive: true);
          await File(
            '${tmp.path}/prompts/skills/dotted.name/SKILL.md',
          ).writeAsString('');
          final violations = await guard.builtinSkillSourceViolations(
            tmp.path,
          );
          expect(violations, hasLength(1));
          expect(violations.single, contains('dotted.name'));
          expect(violations.single, contains('EMPTY'));
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );

    test('fixture: prompts/skills missing entirely fails loudly', () async {
      final tmp = await Directory.systemTemp.createTemp('builtin_skill_guard');
      try {
        final violations = await guard.builtinSkillSourceViolations(tmp.path);
        expect(violations, hasLength(1));
        expect(violations.single, contains('missing entirely'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('builtinSkillNameParityViolations — packaging misses entries', () {
    test('flags a packaged artifact missing a source skill', () {
      final violations = guard.builtinSkillNameParityViolations(
        {'create-goal', 'js-apps', 'self-settings'},
        {'create-goal', 'self-settings'},
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('js-apps'));
      expect(violations.single, contains('gen_prompts'));
    });

    test('flags packaged entries with no on-disk source', () {
      final violations = guard.builtinSkillNameParityViolations(
        {'create-goal'},
        {'create-goal', 'ghost'},
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('ghost'));
    });

    test('full parity is clean', () {
      expect(
        guard.builtinSkillNameParityViolations(
          {'a', 'b'},
          {'a', 'b'},
        ),
        isEmpty,
      );
    });

    test('packaged map embeds EXACTLY the on-disk sources, byte-identical', () {
      final dir = Directory('prompts/skills');
      final sources = <String, String>{
        for (final d in dir.listSync().whereType<Directory>())
        p.basename(d.path): File('${d.path}/SKILL.md').readAsStringSync(),
      };
      expect(builtinSkillFiles.keys.toSet(), sources.keys.toSet());
      for (final entry in sources.entries) {
        expect(
          builtinSkillFiles[entry.key],
          entry.value,
          reason:
              'compiled SKILL.md for "${entry.key}" drifted from its '
              'prompts/skills source — rerun `dart run '
              'scripts/gen_prompts.dart`',
        );
      }
    });
  });

  group('verifyBuiltinSkills — the composed gate the workflows run', () {
    test('current tree passes end to end', () async {
      expect(await guard.verifyBuiltinSkills(repoRoot: '.'), isEmpty);
    });
  });
}
