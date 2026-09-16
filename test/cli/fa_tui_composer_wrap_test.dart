// Composer soft-wrap (issue #467): the composer is a chat input, not a
// shell line — long input soft-wraps across rows (word boundary preferred,
// hard break for overlong words, grapheme-aware widths), the cursor tracks
// its true position across wrapped rows, and busy-ticker rerenders never
// mutate the composer viewport.
//
// AC map: AC1 UT-wrap-long-line · AC2 UT-ticker-stability · AC4
// IT-cursor-navigation (Home/End across wrapped rows) · AC5
// GOLDEN-composer-wrap · E1 overlong word · E2 grapheme integrity ·
// E3 resize re-wrap · E4 history recall.
library;

import 'dart:io' show File, Platform;

import 'package:characters/characters.dart';
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';

import 'package:test/test.dart';

void main() {
  final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)');

  FaTuiCallbacks callbacks() => FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'ready',
    prompt: '',
  );

  FaTuiModel model({int width = 80}) => FaTuiModel(
    callbacks: callbacks(),
    isExited: () => false,
    termWidth: width,
  );

  FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

  FaTuiModel type(FaTuiModel m, String text) {
    for (final ch in text.split('')) {
      m = send(m, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
    }
    return m;
  }

  String stripAnsi(String s) => s.replaceAll(ansi, '');

  /// The composer region of the view: the raw bytes of every row between
  /// the last two full-width rule rows (the input zone frame), plus the
  /// plain rows and the region's base screen row (for cursor math).
  ({List<String> raw, List<String> plain, int baseRow}) composerRegion(
    FaTuiModel m,
  ) {
    final lines = m.view().content.split('\n');
    final rule = '─' * m.termWidth;
    final rules = <int>[
      for (var i = 0; i < lines.length; i++)
        if (stripAnsi(lines[i]) == rule) i,
    ];
    expect(rules.length, greaterThanOrEqualTo(2), reason: 'input zone frame');
    final start = rules[rules.length - 2] + 1;
    final end = rules.last;
    return (
      raw: lines.sublist(start, end),
      plain: [
        for (final line in lines.sublist(start, end)) stripAnsi(line),
      ],
      baseRow: start,
    );
  }

  /// Every row fits the viewport in terminal CELLS (grapheme-aware) — a
  /// row wider than the viewport makes the terminal hardware-wrap and
  /// desyncs the renderer's grid (the artifact class this issue fixes).
  void expectRowsFitViewport(FaTuiModel m) {
    final region = composerRegion(m);
    for (final row in region.plain) {
      expect(
        tuiTextWidth(row),
        lessThanOrEqualTo(m.termWidth),
        reason: 'composer row exceeds the viewport: "$row"',
      );
    }
  }

  /// The wrapped rows walk the same grapheme clusters as the buffer, in
  /// order, none split across a row boundary (E2).
  void expectClustersIntact(FaTuiModel m, String text) {
    final region = composerRegion(m);
    final buffer = text.characters.toList();
    final rendered = [
      for (final row in region.plain) ...row.characters,
    ];
    expect(rendered.length, buffer.length,
        reason: 'wrap must not drop or split clusters');
    for (var i = 0; i < buffer.length; i++) {
      expect(rendered[i], buffer[i], reason: 'cluster $i diverged');
    }
  }

  /// Maps the view cursor into the composer region: (rowInRegion, colCells).
  (int, int) cursorInRegion(FaTuiModel m) {
    final cursor = m.view().cursor!;
    final region = composerRegion(m);
    return (cursor.y - region.baseRow, cursor.x);
  }

  // ── AC1 ──────────────────────────────────────────────────────────────────

  test('AC1 UT-wrap-long-line: 200 chars at 80 cols wrap to 3 word-boundary '
      'rows, first char visible, cursor at the true end', () {
    // 200 chars of prose: 18 full words (10 chars) + 'xy'; at width 80 the
    // greedy word wrap packs 7 words per row (76 cells).
    final text = '${'loremipsum ' * 17}loremipsum xy';
    expect(text.length, 200);
    final m = type(model(), text);

    final region = composerRegion(m);
    expect(region.plain.length, 3, reason: '200 chars / 80 cols → 3 rows');

    // The first character of the buffer opens the first row — the start of
    // the line never slides out of view.
    expect(region.plain.first.startsWith(text.substring(0, 4)), isTrue);

    // Word boundaries: no row cuts a word in half; joins with single
    // spaces reconstruct the buffer exactly (each break dropped exactly
    // one space).
    for (final row in region.plain) {
      expect(row.startsWith(' '), isFalse, reason: 'no leading break space');
      expect(row.endsWith(' '), isFalse, reason: 'no trailing break space');
    }
    expect(region.plain.join(' '), text);

    // Cursor at the TRUE end: last row, one cell past the final glyph.
    final (row, col) = cursorInRegion(m);
    expect(row, 2);
    expect(col, tuiTextWidth(region.plain.last));

    expectRowsFitViewport(m);
  });

  // ── AC2 ──────────────────────────────────────────────────────────────────

  test('AC2 UT-ticker-stability: busy ticks leave the composer region '
      'byte-identical', () {
    final text = '${'loremipsum ' * 17}loremipsum xy';
    var m = type(model(), text);
    m = send(m, const BusyMsg(true, source: 'run'));
    m = send(m, SpinnerTickMsg());
    final before = composerRegion(m);

    for (var tick = 0; tick < 3; tick++) {
      m = send(m, SpinnerTickMsg());
      final after = composerRegion(m);
      expect(
        after.raw.join('\n'),
        before.raw.join('\n'),
        reason: 'tick $tick mutated the composer viewport',
      );
      expect(after.plain.length, before.plain.length);
    }

    // Control: the ticks really do repaint the busy row above the region
    // (a frozen busy row would make the identity assertion vacuous) —
    // capture it on the first and last tick.
    String busyRowOf(FaTuiModel m) {
      final lines = m.view().content.split('\n');
      final rule = '─' * m.termWidth;
      final firstRule = lines.indexWhere((l) => stripAnsi(l) == rule);
      return lines[firstRule - 1];
    }

    final busyAt0 = busyRowOf(m);
    m = send(m, SpinnerTickMsg());
    expect(busyRowOf(m), isNot(busyAt0), reason: 'ticks must repaint busy');
  });

  test('AC2: composer region carries ONLY composer-owned content', () {
    // Mid-run the owner composed a line while tool output streamed: no
    // foreign frame may bleed into the region — every region row is a
    // piece of the composed buffer, nothing else.
    final text = 'git status && echo done';
    var m = type(model(), text);
    m = send(m, const BusyMsg(true, source: 'run'));
    // Simulate streamed tool output into the history above.
    m = send(m, OutputMsg('cat <<EOF\nheredoc payload line\nEOF\n2'));

    final region = composerRegion(m);
    expect(region.plain.join(''), text);
    for (final row in region.plain) {
      expect(row, isNot(contains('heredoc')));
      expect(row, isNot(contains('payload')));
    }
  });

  // ── E1 ───────────────────────────────────────────────────────────────────

  test('E1: an overlong word hard-breaks at the viewport with no wrap loop',
      () {
    final url = 'https://example.com/${'a' * 180}'; // one 200-char word
    final m = type(model(), url);

    final region = composerRegion(m);
    expect(region.plain.length, 3); // ceil(200 / 80)
    for (final row in region.plain) {
      expect(tuiTextWidth(row), lessThanOrEqualTo(80));
    }
    expect(region.plain.join(), url); // hard breaks drop nothing
    final (row, col) = cursorInRegion(m);
    expect(row, 2);
    expect(col, 40); // 200 = 80 + 80 + 40
  });

  // ── E2 ───────────────────────────────────────────────────────────────────

  test('E2: wide graphemes never overflow the row in cells', () {
    // 79 ASCII + one 2-cell CJK glyph = 81 CELLS in 80 code units: the
    // code-unit split used to overflow the row and hardware-wrap it.
    final text = '${'x' * 79}終${'y' * 79}';
    final m = type(model(), text);
    expectRowsFitViewport(m);
    expectClustersIntact(m, text);
  });

  test('E2: a multi-code-unit emoji cluster is never split across rows', () {
    // 👨‍👩‍👧 is 8 UTF-16 units, ONE grapheme cluster: a code-unit cut at
    // column 80 lands inside it.
    final text = '${'x' * 79}👨‍👩‍👧${'y' * 40}';
    final m = type(model(), text);
    expectRowsFitViewport(m);
    expectClustersIntact(m, text);
    // The cursor still maps to the true end (cells, not code units).
    final (row, col) = cursorInRegion(m);
    expect(row, composerRegion(m).plain.length - 1);
    expect(col, tuiTextWidth(composerRegion(m).plain.last));
  });

  // ── E3 ───────────────────────────────────────────────────────────────────

  test('E3: a resize re-wraps and keeps the cursor at the same buffer '
      'offset', () {
    final text = '${'loremipsum ' * 17}loremipsum xy'; // 200 chars
    var m = type(model(width: 80), text);

    // Park the cursor mid-buffer: 100 chars in.
    m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.home)));
    for (var i = 0; i < 100; i++) {
      m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.right)));
    }

    m = m.copyWith(termWidth: 40);
    final region = composerRegion(m);
    expect(region.plain.length, greaterThan(3), reason: 'narrower → more rows');
    for (final row in region.plain) {
      expect(tuiTextWidth(row), lessThanOrEqualTo(40));
    }

    // The cursor sits at the same BUFFER position: break-point spaces are
    // dropped from the rendered rows, so compare the space-stripped
    // character stream up to the cursor with the buffer's stream up to
    // offset 100 — the same visible characters in the same order.
    final (row, col) = cursorInRegion(m);
    final visible = [
      for (var i = 0; i < row; i++) region.plain[i],
      region.plain[row].substring(0, col),
    ].join();
    expect(
      visible.replaceAll(' ', ''),
      text.substring(0, 100).replaceAll(' ', ''),
    );
  });

  test('E3: an exact-width cursor keeps its own trailing row', () {
    final m = type(model(width: 80), 'x' * 160);
    final region = composerRegion(m);
    expect(region.plain.length, 3); // 2 full rows + the trailing row
    final (row, col) = cursorInRegion(m);
    expect(row, 2);
    expect(col, 0);
  });

  // ── E4 ───────────────────────────────────────────────────────────────────

  test('E4: history recall of a long entry renders wrapped, cursor at end',
      () {
    final text = '${'loremipsum ' * 17}loremipsum xy'; // 200 chars
    var m = model();
    m = type(m, text);
    m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    expect(m.inputText, '');

    m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.up)));
    expect(m.inputText, text);

    final region = composerRegion(m);
    expect(region.plain.length, 3);
    expect(region.plain.join(' '), text);
    final (row, col) = cursorInRegion(m);
    expect(row, 2);
    expect(col, tuiTextWidth(region.plain.last));
  });

  // ── AC4 ──────────────────────────────────────────────────────────────────

  test('AC4: Home/End reach the first/last wrapped row', () {
    final text = '${'loremipsum ' * 17}loremipsum xy'; // 3 wrapped rows
    var m = type(model(), text);

    m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.home)));
    expect(cursorInRegion(m), (0, 0));

    m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.end)));
    final region = composerRegion(m);
    expect(cursorInRegion(m), (2, tuiTextWidth(region.plain.last)));
  });

  // ── AC5 goldens ──────────────────────────────────────────────────────────

  group('AC5 GOLDEN-composer-wrap', () {
    // Regenerate with: FA_UPDATE_COMPOSER_GOLDENS=1 dart test \\
    //   test/cli/fa_tui_composer_wrap_test.dart
    final update = Platform.environment.containsKey(
      'FA_UPDATE_COMPOSER_GOLDENS',
    );
    const themes = ['ohmypi-dark', 'ohmypi-light'];

    /// One composed screen state: rules + wrapped composer rows + status
    /// row, with the cursor position recorded (the ANSI file cannot carry
    /// the physical cursor). [text] null = empty 1-row composer.
    List<String> sampleScreen({
      required int width,
      String? text,
      required bool cursorMid,
    }) {
      var m = model(width: width);
      m = m.copyWith(
        termHeight: 24,
      ); // deterministic viewport
      if (text != null) m = type(m, text);
      if (cursorMid) {
        m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.home)));
        final half = (text!.length ~/ 2);
        for (var i = 0; i < half; i++) {
          m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.right)));
        }
      }
      final region = composerRegion(m);
      final rule = '─' * width;
      final (crow, ccol) = cursorInRegion(m);
      return [
        rule,
        ...region.raw,
        rule,
        'status: ready',
        'cursor: row=$crow col=$ccol',
      ];
    }

    final states = <(String, int, String?, bool)>[
      ('1row-end', 80, 'git status', false),
      ('1row-mid', 80, 'git status', true),
      ('2row-end', 80, 'x' * 90, false),
      ('2row-mid', 80, 'x' * 90, true),
      ('3row-end', 80, '${'loremipsum ' * 17}loremipsum xy', false),
      ('3row-mid', 80, '${'loremipsum ' * 17}loremipsum xy', true),
    ];

    for (final theme in themes) {
      for (final (name, width, text, cursorMid) in states) {
        test('golden: composer_wrap_$name-$theme', () {
          FaThemeController.instance.reset();
          expect(FaThemeController.instance.switchTo(theme), isTrue);
          final rendered = sampleScreen(
            width: width,
            text: text,
            cursorMid: cursorMid,
          ).join('\n');
          final file = File('test/cli/goldens/composer_wrap_$name-$theme.ans');
          if (update) {
            file.writeAsStringSync('$rendered\n');
            return;
          }
          expect(
            rendered,
            file.readAsStringSync().trim(),
            reason: 'composer wrap drift in $name/$theme; regenerate with '
                'FA_UPDATE_COMPOSER_GOLDENS=1',
          );
        });
      }
    }
  });
}
