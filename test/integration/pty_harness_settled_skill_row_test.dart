// Unit proof for `settledMidSessionSkillRow` — the `/skills` frame-settle
// predicate behind the gh-1639 flake fix. Top-level and pure so the
// predicate is provable without a PTY (same convention as
// `maskedValueRow` / `settledJobNumbers`). Runs in the DEFAULT suite (no
// integration tag).
//
// Regression (gh-1639; PTY/CLI integration gate runs 38802108913 +
// 38649168502, two distinct SHAs): the wait anchored the BARE flag —
// `waitForScreen('added mid-session')` returns the FIRST frame containing
// it — while a fresh `/skills` listing paints over several PTY writes.
// On loaded runners the 50 ms poll tick landed mid-paint: the `latecomer`
// row was complete, the `latecomer2` row truncated, the flagged-row assert
// saw 1 ≠ 2. The frames below are the EXACT red captures; the settled
// predicate must refuse both and accept only the completed listing.
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  // The exact mid-paint frames from the two gh-1639 gate runs (skills
  // listing rows only; both show `latecomer` complete WITH its flag).
  const redRun38802108913 =
      'skills:\n'
      '  latecomer — Mid-session arrival  /tmp/fa1440w_EZPXBM/.fah/skills/'
      'latecomer/SKILL.md (project, fah; added mid-session)\n'
      '  latecomer2 — Mid-session arrival 2  /tmp/fa1440w_EZPXBM/.fah/skills/';
  const redRun38649168502 =
      'skills:\n'
      '  latecomer — Mid-session arrival  /tmp/fa1440w_FPVNKN/.fah/skills/'
      'latecomer/SKILL.md (project, fah; added mid-session)\n'
      '  latecomer2 — Mid-sessio';

  const settled =
      'skills:\n'
      '  latecomer — Mid-session arrival  /tmp/fa1440w_EZPXBM/.fah/skills/'
      'latecomer/SKILL.md (project, fah; added mid-session)\n'
      '  latecomer2 — Mid-session arrival 2  /tmp/fa1440w_EZPXBM/.fah/skills/'
      'latecomer2/SKILL.md (project, fah; added mid-session)';

  int flaggedRows(String screen) => RegExp(
    r'^.*added mid-session.*$',
    multiLine: true,
  ).allMatches(screen).length;

  group('settledMidSessionSkillRow', () {
    test('refuses both gh-1639 mid-paint frames — the wait keeps polling '
        'instead of anchoring a partial listing', () {
      expect(
        settledMidSessionSkillRow('latecomer2').allMatches(redRun38802108913),
        isEmpty,
        reason: 'latecomer2 truncated at `…/.fah/skills/` (run 38802108913)',
      );
      expect(
        settledMidSessionSkillRow('latecomer2').allMatches(redRun38649168502),
        isEmpty,
        reason: 'latecomer2 truncated at `Mid-sessio` (run 38649168502)',
      );
    });

    test('the completed `latecomer` row alone does NOT satisfy the '
        '`latecomer2` anchor — the exact early-return that flaked', () {
      expect(
        settledMidSessionSkillRow(
          'latecomer2',
        ).allMatches(redRun38802108913.split('\n')[1]),
        isEmpty,
      );
    });

    test('accepts the settled listing; its match is the fully painted '
        'second flagged row', () {
      final matches = settledMidSessionSkillRow(
        'latecomer2',
      ).allMatches(settled).toList();

      expect(matches, hasLength(1));
      expect(matches.single.group(0), contains('latecomer2/SKILL.md'));
      expect(flaggedRows(settled), 2);
    });

    test('a mid-paint frame can never carry the flag on the truncated row '
        '— the flag renders at row END, so a same-row match implies the '
        'whole row landed', () {
      // The trailing `)` must be on the SAME screen row: a wrapped tail
      // (rows wider than the terminal) leaves the flag on the next screen
      // row, where `.` never follows it.
      const wrappedFlag =
          'skills:\n'
          '  latecomer2 — Mid-session arrival 2  /tmp/fa1440w_EZPXBM/'
          '.fah/skills/latecomer2/SKILL.md (project, fah; added\n'
          'mid-session)';
      expect(
        settledMidSessionSkillRow('latecomer2').allMatches(wrappedFlag),
        isEmpty,
      );
    });
  });
}
