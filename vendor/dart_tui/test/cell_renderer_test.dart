import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Internal imports — use package paths to access src directly
import 'package:dart_tui/src/bubbles/style.dart';
import 'package:dart_tui/src/renderer.dart';
import 'package:dart_tui/src/view.dart';

void main() {
  group('CellRenderer', () {
    late StringBuffer buf;
    late _StringSink sink;
    late CellRenderer renderer;

    setUp(() {
      buf = StringBuffer();
      sink = _StringSink(buf);
      renderer = CellRenderer(
        output: sink,
        logSink: null,
        defaultAltScreen: false,
        defaultHideCursor: false,
      );
    });

    test('renders first frame with all cells', () {
      renderer.render(newView('ab'));
      final output = buf.toString();
      expect(output, contains('a'));
      expect(output, contains('b'));
    });

    test('clears unknown initial row content before writing', () {
      renderer.render(newView('short'));

      expect(buf.toString(), contains('\x1b[1;1H\x1b[K'));
    });

    test('strips controls from window titles', () {
      renderer.render(View(
        content: 'value',
        windowTitle: 'safe\x07\x1b]2;owned\x07\x9c\x7fevil',
      ));

      expect(buf.toString(), contains('\x1b]0;safe]2;ownedevil\x07'));
      expect(buf.toString(), isNot(contains('\x1b]2;owned')));
    });

    test('second frame with single char change emits only that cell', () {
      renderer.render(newView('hello'));
      buf.clear();
      // Change only the last character
      renderer.render(newView('hellX'));
      final output = buf.toString();
      // Should contain the changed character
      expect(output, contains('X'));
      // Should NOT re-render unchanged 'hell' characters (those positions should not appear)
      // We verify there is exactly one cursor-move sequence (to position of 'o'→'X')
      final cursorMoves = RegExp(r'\x1b\[\d+;\d+H').allMatches(output).length;
      expect(cursorMoves, equals(1));
    });

    test('positions changes after wide graphemes by terminal column', () {
      renderer.render(newView('你a'));
      buf.clear();

      renderer.render(newView('你b'));

      expect(buf.toString(), equals('\x1b[1;3Hb'));
    });

    test('applies cursor position, shape, blink, and color', () {
      renderer.render(View(
        content: 'value',
        cursor: const Cursor(
          x: 4,
          y: 2,
          color: 0x12abef,
          shape: CursorShape.underline,
          blink: false,
        ),
      ));

      final output = buf.toString();
      expect(output, contains('\x1b[4 q'));
      expect(output, contains('\x1b]12;#12abef\x07'));
      expect(output, endsWith('\x1b[3;5H'));
    });

    test('applies and resets terminal colors and progress', () {
      final active = View(
        content: 'value',
        foregroundColor: 0x123456,
        backgroundColor: 0xabcdef,
        progressBar: const ProgressBar(
          state: ProgressBarState.warning,
          value: -20,
        ),
      );

      renderer.render(active);

      expect(buf.toString(), contains('\x1b]10;#123456\x07'));
      expect(buf.toString(), contains('\x1b]11;#abcdef\x07'));
      expect(buf.toString(), contains('\x1b]9;4;4;0\x07'));

      buf.clear();
      renderer.render(active);
      expect(buf.toString(), isEmpty);

      renderer.render(newView('value'));
      expect(
        buf.toString(),
        equals('\x1b]110\x07\x1b]111\x07\x1b]9;4;0\x07'),
      );
    });

    test('release resets active terminal colors and progress', () {
      renderer.render(View(
        content: 'value',
        foregroundColor: 0x123456,
        backgroundColor: 0xabcdef,
        progressBar: const ProgressBar(
          state: ProgressBarState.error,
          value: 30,
        ),
      ));
      buf.clear();

      renderer.release();

      expect(
        buf.toString(),
        startsWith('\x1b]110\x07\x1b]111\x07\x1b]9;4;0\x07'),
      );
    });

    test('negotiates and resets keyboard enhancements', () {
      final enhanced = View(
        content: 'value',
        keyboardEnhancements: const KeyboardEnhancements(
          reportEventTypes: true,
          reportAlternateKeys: true,
          reportAllKeysAsEscapeCodes: true,
          reportAssociatedText: true,
        ),
      );

      renderer.render(enhanced);

      expect(buf.toString(), contains('\x1b[>4;2m\x1b[=31;1u\x1b[?u'));

      buf.clear();
      renderer.render(enhanced);
      expect(buf.toString(), isEmpty);

      renderer.render(View(
        content: 'value',
        keyboardEnhancements: const KeyboardEnhancements(
          reportAlternateKeys: true,
        ),
      ));
      expect(buf.toString(), equals('\x1b[>4;2m\x1b[=5;1u\x1b[?u'));

      buf.clear();
      renderer.release();
      expect(buf.toString(), startsWith('\x1b[>4m\x1b[=0;1u'));
    });

    test('treats emoji sequences as one two-column grapheme', () {
      renderer.render(newView('A❤️B'));
      buf.clear();

      renderer.render(newView('A❤️C'));

      // VS16 emoji widths are not universally agreed (wcwidth-based
      // terminals say 1 cell), so the row repaints whole instead of
      // addressing cells past the cluster (#342): the sequence stays
      // unsplit and the bytes stay faithful for screen-scrapers.
      expect(buf.toString(), contains('A❤️C'));
      expect(buf.toString(), isNot(contains('\x1b[1;4H')));
    });

    test('does not render ST-terminated OSC payloads or terminators', () {
      renderer.render(newView('A\x1b]0;hidden\x1b\\B'));

      expect(buf.toString(), endsWith('\x1b[1;1HAB'));
    });

    test('does not render ST-terminated DCS payloads or terminators', () {
      renderer.render(newView('A\x1bP1;2|hidden\x1b\\B'));

      expect(buf.toString(), endsWith('\x1b[1;1HAB'));
    });

    test('preserves hyperlinks and combined rich underline state', () {
      final content = const Style(
        underlineStyle: UnderlineStyle.curly,
        underlineColor: RgbColor(12, 34, 56),
        hyperlinkUrl: 'https://example.com',
        hyperlinkParams: 'id=cell',
      ).render('linked');

      renderer.render(newView(content));

      expect(
        buf.toString(),
        contains('\x1b]8;id=cell;https://example.com\x1b\\'),
      );
      expect(buf.toString(), contains('\x1b[4:3m'));
      expect(buf.toString(), contains('\x1b[58;2;12;34;56m'));
      expect(buf.toString(), endsWith('\x1b[0m\x1b]8;;\x1b\\'));
    });

    test('repaints unchanged text when only its hyperlink changes', () {
      renderer.render(newView(
        const Style(hyperlinkUrl: 'https://one.example').render('same'),
      ));
      buf.clear();

      renderer.render(newView(
        const Style(hyperlinkUrl: 'https://two.example').render('same'),
      ));

      expect(buf.toString(), contains('https://two.example'));
      expect(buf.toString(), contains('same'));
    });

    test('unchanged frame emits no diff output', () {
      renderer.render(newView('hello'));
      buf.clear();
      renderer.render(newView('hello'));
      final output = buf.toString();
      // No cursor moves or character writes for identical content
      expect(RegExp(r'\x1b\[\d+;\d+H').allMatches(output), isEmpty);
    });

    test('repaints unchanged content after a screen change', () {
      renderer.render(newView('same'));
      buf.clear();

      renderer.render(View(content: 'same', altScreen: true));

      expect(buf.toString(), contains('\x1b[?1049h'));
      expect(buf.toString(), contains('\x1b[1;1Hsame'));
    });

    test('clearScreen resets grid state', () {
      renderer.render(newView('hello'));
      renderer.clearScreen();
      buf.clear();
      renderer.render(newView('hello'));
      final output = buf.toString();
      // After clear, full re-render
      expect(output, contains('hello'));
    });
  });

  // ── Differential renderer — issue #274 (AC1, E1, E2, E3) ──────────────────

  group('CellRenderer differential #274', () {
    late StringBuffer buf;
    late _StringSink sink;
    late CellRenderer renderer;

    setUp(() {
      buf = StringBuffer();
      sink = _StringSink(buf);
      renderer = CellRenderer(
        output: sink,
        logSink: null,
        defaultAltScreen: false,
        defaultHideCursor: false,
      );
    });

    test('AC1: one char changed emits exactly one CUP + the char', () {
      renderer.render(newView('hello'));
      buf.clear();
      renderer.render(newView('hellX'));
      expect(buf.toString(), '\x1b[1;5HX');
    });

    test('AC1: one line inserted repaints only the shifted tail', () {
      renderer.render(newView('a\nb\nc'));
      buf.clear();
      renderer.render(newView('a\nX\nb\nc'));
      expect(buf.toString(), '\x1b[2;1HX\x1b[3;1Hb\x1b[4;1Hc');
    });

    test('AC1: style-only change repaints the cells with new SGR only', () {
      final red = const Style(foregroundRgb: RgbColor(255, 0, 0)).render('ab');
      final blue = const Style(foregroundRgb: RgbColor(0, 0, 255)).render('ab');
      renderer.render(newView(red));
      buf.clear();
      renderer.render(newView(blue));
      expect(buf.toString(), '\x1b[1;1H\x1b[38;2;0;0;255mab\x1b[0m');
    });

    test('AC1: scroll-by-1 up is one SU op plus only the new bottom row', () {
      final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
      final next = [for (var i = 1; i <= 10; i++) 'row-$i'].join('\n');
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '\x1b[1S\x1b[10;1Hrow-10\x1b[K');
    });

    test('AC1: scroll-by-1 down is one SD op plus only the new top row', () {
      final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
      final next = ['row-new', for (var i = 0; i < 9; i++) 'row-$i'].join('\n');
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '\x1b[1T\x1b[1;1Hrow-new\x1b[K');
    });

    test('AC1: styled rows ride the scroll — op + plain tail only', () {
      final styled =
          const Style(foregroundRgb: RgbColor(0, 255, 0)).render('g4');
      final prev =
          [for (var i = 0; i < 10; i++) i == 4 ? styled : 'row-$i'].join('\n');
      final next = [
        for (var i = 1; i <= 10; i++) i == 4 ? styled : 'row-$i',
      ].join('\n');
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '\x1b[1S\x1b[10;1Hrow-10\x1b[K');
    });

    test('scroll frame leaves the diff cache intact (next idle = 0 bytes)', () {
      final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
      final next = [for (var i = 1; i <= 10; i++) 'row-$i'].join('\n');
      renderer.render(newView(prev));
      renderer.render(newView(next));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(), '');
    });

    test('AC3: budget-exceeded noise falls back to the cell diff', () {
      final styled =
          const Style(foregroundRgb: RgbColor(0, 255, 0)).render('g4');
      final prev = [for (var i = 0; i < 4; i++) 'r$i', styled].join('\n');
      final next = ['r1', 'x2', 'x3', 'r4', styled].join('\n');
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      final out = buf.toString();
      // Three noisy overlap rows blow the mismatch budget, and no smaller
      // shift matches a majority — no scroll op may fire for any k (also
      // rules out the degenerate zero-match k a budget-only check allows).
      expect(out.contains('S') || out.contains('T'), isFalse);
      // Styled row unchanged; 4 changed rows, one CUP each — the optimal
      // cell-diff fallback.
      expect(RegExp(r'\x1b\[\d+;\d+H').allMatches(out).length, 4);
    });

    test('E1: resize (invalidate) is ONE full repaint, then diffs cleanly', () {
      renderer.render(newView('aaaa\nbbbb\ncccc\ndddd'));
      buf.clear();
      renderer.invalidate();
      renderer.render(newView('ee\nff'));
      // One full repaint: every row cleared and rewritten from column 1 —
      // never the shrink-era stale-row CUP walk.
      expect(
        buf.toString(),
        '\x1b[1;1H\x1b[K\x1b[2;1H\x1b[K\x1b[1;1Hee\x1b[2;1Hff',
      );
      buf.clear();
      renderer.render(newView('ee\nfX'));
      expect(buf.toString(), '\x1b[2;2HX');
    });

    test('AC3: one noisy chrome row keeps the scroll op and is repainted', () {
      final prev = [for (var i = 0; i < 10; i++) 'row-$i'].join('\n');
      final next = [
        'row-1',
        'row-2',
        'spinner', // live chrome rewrote this overlap row across the shift
        'row-4',
        'row-5',
        'row-6',
        'row-7',
        'row-8',
        'row-9',
        'row-10',
      ].join('\n');
      renderer.render(newView(prev));
      buf.clear();
      renderer.render(newView(next));
      expect(buf.toString(),
          '\x1b[1S\x1b[10;1Hrow-10\x1b[K\x1b[3;1Hspinner\x1b[K');
    });

    test('E2: without sync negotiation no 2026 escapes ever appear', () {
      renderer.render(newView('hello'));
      buf.clear();
      renderer.render(newView('hellX'));
      renderer.render(newView('hello'));
      expect(buf.toString(), isNot(contains('?2026')));
    });

    test('E3: diff at a wide-glyph boundary never splits the pair', () {
      renderer.render(newView('中文'));
      buf.clear();
      renderer.render(newView('X文'));
      // The continuation cell is never written independently — only the
      // changed leading cell is.
      expect(buf.toString(), '\x1b[1;1HX文 ');
    });

    test('E3: a wide glyph replacing ASCII moves as one unit', () {
      renderer.render(newView('X文'));
      buf.clear();
      renderer.render(newView('中X'));
      expect(buf.toString(), '\x1b[1;1H中X');
    });
  });

  // #342: East-Asian-AMBIGUOUS glyphs (▸ U+25B8, ✓ U+2713, … emoji-range
  // clusters without VS16) measure 2 cells by dart_tui's emoji heuristics
  // but 1 cell on wcwidth-based terminals (the PTY harness's vendored
  // xterm, tmux, default western xterm/iTerm2). The surgical diff paths
  // address and skip cells by OUR table — on a disagreeing terminal the
  // absolute cursor moves land one column off and skipped "unchanged"
  // cells leave the previous frame's bytes on screen ('▸ tEdi- rovider h').
  // Rows containing such glyphs must stay byte-faithful.
  group('ambiguous-width glyph rows stay byte-faithful (#342)', () {
    late StringBuffer buf;
    late CellRenderer renderer;

    setUp(() {
      buf = StringBuffer();
      renderer = CellRenderer(
        output: _StringSink(buf),
        logSink: null,
        defaultAltScreen: false,
        defaultHideCursor: false,
      );
    });

    test('overlay transition onto a shared ambiguous row repaints it whole', () {
      // The /settings → Edit/Delete picker shape: both rows start with ▸
      // and share cells ('t', 'provider') with the old row.
      renderer.render(newView('▸ test-provider'));
      buf.clear();
      renderer.render(newView('▸ Edit provider'));
      // The new label must arrive as contiguous bytes — screen-scraping
      // consumers (PTY harnesses, tmux panes) read the byte stream.
      expect(buf.toString(), contains('Edit provider'));
    });

    test('bytes converge on a wcwidth (ambiguous=1) terminal', () {
      renderer.render(newView('▸ test-provider'));
      buf.clear();
      renderer.render(newView('▸ Edit provider'));
      expect(_replayAmbiguousNarrow(buf.toString()), contains('Edit provider'));
    });

    test('identical ambiguous row stays byte-silent', () {
      renderer.render(newView('▸ Edit provider'));
      buf.clear();
      renderer.render(newView('▸ Edit provider'));
      expect(buf.toString(), '');
    });

    test('stable wide (CJK) rows keep surgical emission', () {
      renderer.render(newView('你a'));
      buf.clear();
      renderer.render(newView('你b'));
      expect(buf.toString(), equals('\x1b[1;3Hb'));
    });

    // The unstable-repaint branch resets the frame's SGR/OSC-8 trackers to
    // '' after _paintRow — but a surgical write ABOVE the repaint (a styled
    // spinner tick) had left a style open that _paintRow never closes when
    // the repainted row is all-plain: the row painted under the leaked
    // style, the end-of-frame reset was skipped, and the style leaked
    // across frames.
    test('repaint under a styled surgical write ends all attributes off', () {
      renderer.render(newView('\x1b[90m⠋ working\x1b[0m\n▸ provider'));
      buf.clear();
      // Spinner ticks above (styled surgical write); the picker row below
      // loses ▸ and goes all-plain (unstable repaint).
      renderer.render(newView('\x1b[90m⠙ working\x1b[0m\nEdit provider'));

      final output = buf.toString();
      expect(output, contains('Edit provider'));
      expect(_sgrOpenAtEnd(output), isFalse,
          reason: 'frame must end with every SGR attribute off');
    });

    test('repaint under a hyperlinked surgical write closes OSC 8', () {
      renderer.render(newView(
        '${const Style(hyperlinkUrl: 'https://log.example').render('⠋ working')}\n'
        '▸ provider',
      ));
      buf.clear();
      renderer.render(newView(
        '${const Style(hyperlinkUrl: 'https://log.example').render('⠙ working')}\n'
        'Edit provider',
      ));

      final output = buf.toString();
      expect(output, contains('Edit provider'));
      expect(_osc8OpenAtEnd(output), isFalse,
          reason: 'frame must end with no OSC 8 hyperlink open');
    });
  });
}

/// Whether the last SGR sequence in [bytes] leaves attributes open —
/// `\x1b[0m` (and empty/bare-zero parameter forms) close, anything else
/// the renderer emits (Style attr sequences) opens.
bool _sgrOpenAtEnd(String bytes) {
  var open = false;
  for (final m in RegExp(r'\x1b\[([0-9;]*)m').allMatches(bytes)) {
    final params = m.group(1)!;
    open = !params.split(';').every((p) => p.isEmpty || p == '0');
  }
  return open;
}

/// Whether the last OSC 8 in [bytes] leaves a hyperlink open — an empty
/// URI field (`\x1b]8;;\x1b\\`) closes, any other payload opens.
bool _osc8OpenAtEnd(String bytes) {
  var open = false;
  for (final m in RegExp(r'\x1b\]8;([^\x07\x1b]*)').allMatches(bytes)) {
    open = m.group(1)!.split(';').last.isNotEmpty;
  }
  return open;
}

/// Replays renderer bytes on a terminal that measures every printable
/// character one cell wide — the wcwidth / East-Asian-Ambiguous=1 contract
/// of the PTY harness emulator and default western terminals.
String _replayAmbiguousNarrow(String bytes) {
  final rows = List.generate(8, (_) => List<String>.filled(60, ''));
  var r = 0;
  var c = 0;
  var i = 0;
  while (i < bytes.length) {
    if (bytes.codeUnitAt(i) == 0x1b) {
      final cup = RegExp(r'\x1b\[(\d*);(\d*)H').matchAsPrefix(bytes, i);
      if (cup != null) {
        r = (int.tryParse(cup.group(1)!) ?? 1) - 1;
        c = (int.tryParse(cup.group(2)!) ?? 1) - 1;
        i = cup.end;
        continue;
      }
      final el = RegExp(r'\x1b\[[0-9?]*K').matchAsPrefix(bytes, i);
      if (el != null) {
        for (var j = c; j < rows[r].length; j++) {
          rows[r][j] = '';
        }
        i = el.end;
        continue;
      }
      // Any other escape run (SGR, OSC 8, mode sets) is layout-neutral.
      final esc = RegExp(
        r'\x1b(\[[0-9;?]*[A-Za-z]|\][^\x07\x1b]*(\x07|\x1b\\)|.)',
      ).matchAsPrefix(bytes, i);
      i = esc?.end ?? i + 1;
      continue;
    }
    final ch = bytes[i];
    if (ch == '\n') {
      r++;
      c = 0;
    } else if (ch == '\r') {
      c = 0;
    } else {
      rows[r][c] = ch;
      c++;
    }
    i++;
  }
  return rows.map((row) => row.join()).join('\n');
}

class _StringSink implements IOSink {
  _StringSink(this._buf);
  final StringBuffer _buf;
  @override
  void write(Object? obj) => _buf.write(obj);
  @override
  void writeln([Object? obj = '']) => _buf.writeln(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buf.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _buf.writeCharCode(charCode);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
}
