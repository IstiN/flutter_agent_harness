/// gh-1409 AC1/UT-PIN-1..2: `operative:` frontmatter parses into
/// `SkillManifest.operative`; unknown siblings still land in `notes`; a
/// skill without the key yields an empty list and identical downstream
/// behavior; the 512-char line cap rejects blob lines with a parse note.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Skill _skill(String text, {String name = 'deploy'}) => skillFromText(
  text,
  filePath: '/work/.fah/skills/$name/SKILL.md',
  fallbackName: name,
  scope: SkillScope.project,
  source: SkillSource.fah,
)!;

void main() {
  group('operative frontmatter (gh-1409 AC1)', () {
    test('UT-PIN-1: list of strings parses into manifest.operative', () {
      final skill = _skill(
        '---\n'
        'name: fleet\n'
        'description: Board sweeps.\n'
        'operative:\n'
        '  - use fleet_sweep.sh; never hand-roll the gh battery\n'
        '  - classify every issue before dispatch\n'
        '---\n'
        'Body.\n',
      );
      expect(skill.manifest.operative, [
        'use fleet_sweep.sh; never hand-roll the gh battery',
        'classify every issue before dispatch',
      ]);
    });

    test('UT-PIN-1: junk sibling keys still land in notes, skill loads', () {
      final skill = _skill(
        '---\n'
        'name: fleet\n'
        'description: Board sweeps.\n'
        'future_unknown_key: whatever\n'
        'operative:\n'
        '  - stay on method A\n'
        '---\n'
        'Body.\n',
      );
      expect(skill.manifest.operative, ['stay on method A']);
      expect(
        skill.manifest.notes.any(
          (n) => n.contains('future_unknown_key') && n.contains('unknown'),
        ),
        isTrue,
      );
    });

    test(
      'F4/REG-PIN-1: no operative key → empty list, zero pins downstream',
      () {
        final skill = _skill(
          '---\nname: plain\ndescription: Nothing special.\n---\nBody.\n',
        );
        expect(skill.manifest.operative, isEmpty);
        expect(SkillOperativePins.build([skill]).pins, isEmpty);
      },
    );

    test('E1: empty operative list → zero pins', () {
      final skill = _skill(
        '---\nname: e1\ndescription: x\noperative: []\n---\nBody.\n',
      );
      expect(skill.manifest.operative, isEmpty);
    });

    test('E4/UT-PIN-2: line over the 512-char cap is rejected with a note', () {
      final oversized = 'x' * 513;
      final skill = _skill(
        '---\n'
        'name: blobby\n'
        'description: x\n'
        'operative:\n'
        '  - $oversized\n'
        '  - good line\n'
        '---\n'
        'Body.\n',
      );
      expect(skill.manifest.operative, ['good line']);
      expect(
        skill.manifest.notes.any(
          (n) => n.contains('operative') && n.contains('512'),
        ),
        isTrue,
      );
      // The rejected line yields no pin anywhere.
      expect(SkillOperativePins.build([skill]).pins.map((p) => p.line), [
        'good line',
      ]);
    });

    test('a 512-char line exactly at the cap is kept', () {
      final atCap = 'y' * 512;
      final skill = _skill(
        '---\nname: cap\ndescription: x\noperative:\n  - $atCap\n---\nBody.\n',
      );
      expect(skill.manifest.operative, [atCap]);
    });

    test('a non-list scalar operative value becomes a single line', () {
      final skill = _skill(
        '---\nname: one\ndescription: x\noperative: always run make check\n---\nB\n',
      );
      // A plain string is ONE operative line — never space-split.
      expect(skill.manifest.operative, ['always run make check']);
    });

    test('blank list entries are dropped', () {
      final skill = _skill(
        '---\nname: blanks\ndescription: x\noperative:\n  - ""\n  - real\n---\nB\n',
      );
      expect(skill.manifest.operative, ['real']);
    });
  });
}
