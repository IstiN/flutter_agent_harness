import 'package:flutter_agent_harness/src/cli/tui_chrome.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

/// Strips every SGR sequence so assertions read on visible cells only
/// (the AGENTS.md rule: pure render logic tests against ANSI-stripped
/// expectations).
String strip(String s) => s.replaceAll(RegExp('\x1b\\[[0-9;]*m'), '');

/// The visible text of a row with escapes AND the phase-tint padding gone:
/// trims trailing pad spaces the tint painter appended.
String cells(String s) => strip(s).trimRight();

void main() {
  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
    tuiChromeEnabled = true;
  });

  tearDown(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  group('message divider (omp chrome/message-divider.ts)', () {
    test('wide terminal: short default rule of 10 + label', () {
      expect(cells(tuiMessageDivider('Turn 2', 120)), '────────── Turn 2');
    });

    test('rule shrinks to the width budget: min(10, width - label - 1)', () {
      // width 20, label 6 → budget 13 → rule stays 10 … width 14 → 7.
      expect(cells(tuiMessageDivider('Turn 2', 20)), '────────── Turn 2');
      expect(cells(tuiMessageDivider('Turn 2', 14)), '─────── Turn 2');
    });

    test('no rule room: label alone, truncated to width', () {
      expect(cells(tuiMessageDivider('abcdefgh', 6)), 'abcde…');
      // width < 1 clamps to 1 — never a crash, never a negative repeat.
      expect(tuiMessageDividerLayout('x', 0), isNotEmpty);
    });

    test('custom ruleWidth caps the rule', () {
      expect(cells(tuiMessageDivider('T', 80, ruleWidth: 3)), '─── T');
    });

    test('block adds the blank breathing rows', () {
      expect(
        tuiMessageDividerBlock('resume', 80).map(cells),
        ['', '────────── resume', ''],
      );
    });

    test('no profile: raw structure, zero escapes', () {
      FaThemeController.instance.profile = null;
      final row = tuiMessageDivider('Turn', 80);
      expect(row, '────────── Turn');
      expect(row.contains('\x1b'), isFalse);
    });

    test('width math is cell-accurate for wide labels', () {
      // '時時' is 4 cells: budget 80-4-1 = 75 → default 10 wins.
      expect(
        cells(tuiMessageDivider('時時', 80)),
        '────────── 時時',
      );
    });
  });

  group('user bubble (omp chat/user-message.ts)', () {
    test('blank band rows above and below, leading space per row', () {
      final rows = tuiUserBubble(['hello', 'world']);
      expect(rows, hasLength(4));
      expect(cells(rows[0]), '');
      expect(cells(rows[1]), ' hello');
      expect(cells(rows[2]), ' world');
      expect(cells(rows[3]), '');
    });

    test('rows are pre-styled: the bg SGR marker rides every row', () {
      final rows = tuiUserBubble(['hi']);
      for (final row in rows) {
        expect(row.startsWith('\x1b[48'), isTrue, reason: row);
      }
    });

    test('no profile: plain rows, zero escapes', () {
      FaThemeController.instance.profile = null;
      final rows = tuiUserBubble(['hi']);
      expect(rows, ['', ' hi', '']);
    });
  });

  group('tool card (omp render/status-line.ts + getStateBgColor)', () {
    test('status glyphs match the omp symbol defaults', () {
      expect(tuiCardGlyph(TuiCardPhase.pending), '⏳');
      expect(tuiCardGlyph(TuiCardPhase.running), '⟳');
      expect(tuiCardGlyph(TuiCardPhase.success), '✔');
      expect(tuiCardGlyph(TuiCardPhase.error), '✘');
    });

    test('phase tints: success/error ride the named roles, pending the stand-in', () {
      String bgOf(String sgr) => sgr.contains('\x1b[48;2;') ? sgr : '';
      final c = FaThemeController.instance;
      expect(
        tuiCardTintSgr(TuiCardPhase.success),
        c.sgrPrefix(c.current.toolSuccessBg),
      );
      expect(
        tuiCardTintSgr(TuiCardPhase.error),
        c.sgrPrefix(c.current.toolErrorBg),
      );
      // ponytail: pending rides `highlight` until S1 lands toolPendingBg.
      expect(
        bgOf(tuiCardTintSgr(TuiCardPhase.pending)),
        isNotEmpty,
      );
      expect(
        tuiCardTintSgr(TuiCardPhase.running),
        tuiCardTintSgr(TuiCardPhase.pending),
      );
    });

    test('header grammar: glyph title: description [badge] meta·meta', () {
      final header = tuiToolCardHeader(
        const ToolCardSegments(
          title: 'bash',
          description: 'cargo test',
          badge: 'exit 1',
          meta: ['3s', '12 lines'],
        ),
        TuiCardPhase.error,
        120,
      );
      expect(cells(header), '✘ bash: cargo test [exit 1] 3s·12 lines');
    });

    test('squeeze drops from the tail: meta, then badge, then description', () {
      ToolCardSegments segs({String meta = '3s'}) => ToolCardSegments(
            title: 'bash',
            description: 'a very long command that will not fit',
            badge: 'exit 1',
            meta: [meta],
          );
      // head 7 + desc 40 + badge 9 + meta 3 = 59: at 57 the meta drops,
      // everything else fits; at 50 the badge drops too.
      final w1 = cells(
        tuiToolCardHeader(segs(), TuiCardPhase.success, 57),
      );
      expect(w1, isNot(contains('·')));
      expect(w1, contains('[exit 1]'));
      final w2 = cells(
        tuiToolCardHeader(segs(), TuiCardPhase.success, 50),
      );
      expect(w2, isNot(contains('[')));
      expect(w2, startsWith('✔ bash:'));
      // The row NEVER exceeds its budget (cells, not code units).
      for (final (row, budget) in [(w1, 57), (w2, 50)]) {
        expect(tuiTextWidth(row), lessThanOrEqualTo(budget));
      }
    });

    test('card rows: tint + width padding + … N more lines footer', () {
      final card = tuiToolCard(
        const ToolCardSegments(title: 'read', description: 'lib/a.dart'),
        TuiCardPhase.success,
        60,
        detailLines: ['one', 'two', 'three', 'four'],
        maxDetailLines: 2,
      );
      // header + 2 preview rows + footer.
      expect(card, hasLength(4));
      expect(cells(card[0]), startsWith('✔ read: lib/a.dart'));
      expect(cells(card[1]), 'one');
      expect(cells(card[2]), 'two');
      expect(cells(card[3]), '… 2 more lines');
      for (final row in card) {
        expect(tuiTextWidth(strip(row)), 60, reason: row);
      }
    });

    test('short detail: no footer, no padding lies', () {
      final card = tuiToolCard(
        const ToolCardSegments(title: 'read', description: 'a'),
        TuiCardPhase.pending,
        40,
        detailLines: ['only'],
      );
      expect(card, hasLength(2));
      expect(cells(card[1]), 'only');
    });

    test('no profile: card degrades to plain rows, structure intact', () {
      FaThemeController.instance.profile = null;
      final card = tuiToolCard(
        const ToolCardSegments(
          title: 'bash',
          description: 'ls',
          meta: ['2s'],
        ),
        TuiCardPhase.error,
        40,
        detailLines: ['failed'],
      );
      for (final row in card) {
        expect(row.contains('\x1b'), isFalse, reason: row);
      }
      expect(cells(card[0]), '✘ bash: ls 2s');
      expect(cells(card[1]), 'failed');
    });
  });
}
