// The band composer (issue #806, story S3 of #802): the omp status line
// attaches as the composer's top band (flush-left, one reserved row), the
// `╰─ ` prompt gutter leads the first row and indents the continuations,
// and the legacy bottom rule + dim footer retire in TUI mode. The
// `tui.classic` kill switch renders the legacy chrome byte-identically;
// NO_COLOR degrades the band to shape-only raw text.
//
// AC map: AC-band-widths (attachment at 40..200) · AC-gutter-shape
// (wrapped/multiline) · AC-classic-parity (byte-identical legacy tail) ·
// AC-no-color (degrade) · AC-caret-gutter (click + caret math) — the
// line-mode and headless byte invariants ride the untouched code paths
// plus the agent_cli line-mode suites.
library;

import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_status_line.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart'
    show tuiPadRight, tuiTextWidth;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart'
    show ColorProfile, FaThemeController, tuiDim;

import 'package:test/test.dart';

final _ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)');

String _stripAnsi(String s) => s.replaceAll(_ansi, '');

StatusLineSnapshot _snapshot({bool idle = true}) => StatusLineSnapshot(
  cwd: '/Users/ag/work/flutter_agent_harness/lib/src/cli',
  homeDir: '/Users/ag',
  workRoot: '/Users/ag/work/flutter_agent_harness',
  modelName: 'zai/glm-5.3-flash',
  approvalMode: 'yolo',
  contextTokens: 4200,
  contextWindow: 10000,
  tokensIn: 1500,
  tokensOut: 300,
  costUsd: 1.25,
  sessionName: 'band-composer',
  idle: idle,
);

final _engine = TuiStatusLine(spec: resolveStatusLineSpec(null));

FaTuiCallbacks _callbacks({
  StatusLineSnapshot Function()? snapshot,
  TuiStatusLine? engine,
}) =>
    FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'cwd · ctx 42% · legacy footer',
      prompt: '',
      statusSnapshot: snapshot,
      statusLineEngine: snapshot == null ? null : (engine ?? _engine),
    );

/// Band-attached callbacks (the host default without `tui.classic`).
FaTuiCallbacks _bandCallbacks() => _callbacks(snapshot: _snapshot);

/// Classic callbacks (`tui.classic: true` — the host passes no seam).
FaTuiCallbacks _classicCallbacks() => _callbacks();

FaTuiModel _model(FaTuiCallbacks callbacks, {int width = 80}) => FaTuiModel(
  callbacks: callbacks,
  isExited: () => false,
  termWidth: width,
  termHeight: 24,
);

FaTuiModel _type(FaTuiModel m, String text) =>
    m.copyWith(inputText: text, cursor: text.length);

List<String> _plainRows(FaTuiModel m) =>
    m.view().content.split('\n').map(_stripAnsi).toList();

int _gutterRowIndex(List<String> rows) =>
    rows.indexWhere((row) => row.startsWith('╰─ '));

void main() {
  tearDown(() {
    FaThemeController.instance.profile = ColorProfile.trueColor;
  });

  group('band attachment (#806)', () {
    for (final width in const [40, 60, 79, 80, 120, 160, 199, 200]) {
      test('renders the status band above the composer at $width cols', () {
        final m = _model(_bandCallbacks(), width: width);
        final rows = _plainRows(m);
        final band = _engine.render(_snapshot(), width).first;
        final gutterRow = _gutterRowIndex(rows);
        expect(gutterRow, greaterThan(0), reason: 'composer first row');
        // The band sits DIRECTLY above the `╰─ ` prompt row — the omp
        // top-band attachment — flush-left and exactly the engine's
        // width-exact raw render for that width.
        expect(rows[gutterRow - 1], band);
        expect(tuiTextWidth(rows[gutterRow - 1]), width);
        // The legacy tail is gone: no full-width rule, no dim footer.
        expect(
          rows.where((row) => row == '─' * width),
          isEmpty,
          reason: 'no bottom rule row',
        );
        expect(rows.join('\n'), isNot(contains('legacy footer')));
      });
    }

    test('the styled band carries the band background through the seam', () {
      final m = _model(_bandCallbacks());
      final raw = m.view().content.split('\n');
      final gutterRow = _gutterRowIndex(_plainRows(m));
      final bandRow = raw[gutterRow - 1];
      // Every band span paints the bandBg role's tint behind the role
      // color — a 48;2 truecolor background escape must be on the row.
      expect(bandRow, contains('\x1b[48;2;'));
    });

    test('statusLine.transparent drops the fill, keeps the row flush', () {
      final m = _model(
        _callbacks(
          snapshot: _snapshot,
          engine: TuiStatusLine(
            spec: resolveStatusLineSpec(
              const StatusLineConfig(transparent: true),
            ),
          ),
        ),
      );
      final raw = m.view().content.split('\n');
      final bandRow = raw[_gutterRowIndex(_plainRows(m)) - 1];
      // No bandBg fill, no gap fill — the terminal background shows
      // through (omp `transparent`, mirroring the #831 round-2 writer).
      expect(bandRow, isNot(contains('\x1b[48;2;')));
      // The row still covers the full width (stale cells die at the
      // right edge) — plain padding after the reset.
      expect(tuiTextWidth(_stripAnsi(bandRow)), m.termWidth);
    });

    test('idle renders dim, streaming renders lit (write-time seam)', () {
      String bandOf(bool idle) {
        final callbacks = _callbacks(snapshot: () => _snapshot(idle: idle));
        final raw = _model(callbacks).view().content.split('\n');
        return raw[_gutterRowIndex(_plainRows(_model(callbacks))) - 1];
      }

      // Idle maps every non-brand span through theme.muted; the lit pass
      // paints the role colors — the rows must differ.
      expect(bandOf(true), isNot(bandOf(false)));
    });
  });

  group('gutter shape (#806)', () {
    test('first row carries the cue, wrapped continuations indent', () {
      final m = _type(_model(_bandCallbacks()), '${'a' * 100} end');
      final rows = _plainRows(m);
      final gutterRow = _gutterRowIndex(rows);
      expect(gutterRow, greaterThan(0));
      expect(rows[gutterRow].startsWith('╰─ a'), isTrue);
      // The continuation carries a plain 3-space indent (the wrap width
      // is the content width, so nothing overflows the glass).
      expect(rows[gutterRow + 1].startsWith('   '), isTrue);
      expect(rows[gutterRow + 1].startsWith('    '), isFalse);
      for (final row in rows.skip(gutterRow)) {
        expect(tuiTextWidth(row), lessThanOrEqualTo(m.termWidth));
      }
    });

    test('multiline input keeps the cue on row zero only', () {
      final m = _type(_model(_bandCallbacks()), 'one\ntwo');
      final rows = _plainRows(m);
      final gutterRow = _gutterRowIndex(rows);
      expect(rows[gutterRow], '╰─ one');
      expect(rows[gutterRow + 1], '   two');
    });

    test('caret clicks land through the gutter', () {
      FaTuiModel send(FaTuiModel m, Mouse msg) {
        var (next, _) = m.update(MouseClickMsg(msg));
        (next, _) = next.update(MouseReleaseMsg(msg));
        return next as FaTuiModel;
      }

      Mouse at(int x, int y) => Mouse(x: x, y: y, button: MouseButton.left);
      final m = _type(_model(_bandCallbacks()), 'hello world');
      final rows = _plainRows(m);
      final inputY = _gutterRowIndex(rows);
      // A click inside the gutter clamps to the text start; a click at
      // column 5 lands on the second grapheme (5 - 3 gutter cells).
      expect(send(m, at(1, inputY)).cursor, 0);
      expect(send(m, at(5, inputY)).cursor, 2);
      // A classic model clicks unchanged (no gutter offset).
      final classic = _type(_model(_classicCallbacks()), 'hello world');
      final classicY = _plainRows(classic).indexWhere(
        (row) => row.contains('hello world'),
      );
      expect(send(classic, at(1, classicY)).cursor, 1);
    });

    test('the physical caret parks after the gutter', () {
      final m = _model(_bandCallbacks()).copyWith(inputText: 'ab', cursor: 2);
      final view = m.view();
      expect(view.cursor, isNotNull);
      expect(view.cursor!.x, 5, reason: 'gutter (3) + text column (2)');
      // Classic keeps the bare text column.
      final classic = _model(
        _classicCallbacks(),
      ).copyWith(inputText: 'ab', cursor: 2);
      expect(classic.view().cursor!.x, 2);
    });

    test('the caret homes on the FIRST input row (band row math)', () {
      // The band sits ABOVE the input and nothing paints between them:
      // the caret row is exactly the `╰─ ` cue row (the off-by-one homed
      // it one row BELOW the text).
      final m = _type(_model(_bandCallbacks()), 'hello world');
      expect(m.view().cursor!.y, _gutterRowIndex(_plainRows(m)));
      // A second input line homes on its own row.
      final multi = _type(_model(_bandCallbacks()), 'one\ntwo');
      expect(
        multi.view().cursor!.y,
        _gutterRowIndex(_plainRows(multi)) + 1,
        reason: 'cursor on the `two` row',
      );
    });

    test('under 4 columns the gutter stands down, rows stay in the glass', () {
      final m = _type(_model(_bandCallbacks(), width: 3), 'abcdef');
      final rows = _plainRows(m);
      expect(
        rows.where((row) => row.startsWith('╰─ ')),
        isEmpty,
        reason: 'the cue cannot fit under 4 columns',
      );
      for (final row in rows) {
        expect(tuiTextWidth(row), lessThanOrEqualTo(3));
      }
      final view = m.view();
      expect(view.cursor, isNotNull);
      expect(view.cursor!.x, lessThan(3));
    });

    test('prompt frames keep the legacy top rule (frame-shape gate)', () {
      // Band config on + an open prompt: the prompt zone replaces the
      // composer, so the frame is legacy-shaped and the rule chrome
      // paints — retirement follows the frame shape, never the bare
      // config flag.
      final m = _model(
        _bandCallbacks(),
      ).copyWith(prompt: TuiPromptState(TextPromptSpec(question: 'Pick')));
      expect(
        _plainRows(m).where((row) => row == '─' * m.termWidth),
        isNotEmpty,
        reason: 'the legacy top rule paints in prompt frames',
      );
      // And a band COMPOSER frame still retires it.
      expect(
        _plainRows(_model(_bandCallbacks())).where((row) => row == '─' * 80),
        isEmpty,
      );
    });
  });

  group('tui.classic kill switch (#806 AC3.5)', () {
    test('legacy composer tail is byte-identical (rule + dim footer)', () {
      const width = 80;
      final classic = _model(_classicCallbacks(), width: width);
      final raw = classic.view().content.split('\n');
      // Golden-ish: the tail equals the legacy construction exactly —
      // the dim full-width rule, then the padded dim one-line footer.
      final expectedFooter = tuiDim(
        tuiPadRight('cwd · ctx 42% · legacy footer', width),
      );
      expect(raw[raw.length - 1], expectedFooter);
      expect(_stripAnsi(raw[raw.length - 2]), '─' * width);
      // No band fill, no gutter anywhere in the classic frame.
      expect(raw.join('\n'), isNot(contains('╰─ ')));
      expect(raw.join('\n'), isNot(contains('\x1b[48;2;')));
    });

    test('classic wrap width is the full terminal width', () {
      final m = _type(_model(_classicCallbacks()), 'a' * 100);
      final rows = _plainRows(m);
      // No gutter prefix anywhere; rows wrap at the full width.
      expect(rows.where((row) => row.startsWith('╰─ ')), isEmpty);
      expect(
        rows.any((row) => row.startsWith('a') && tuiTextWidth(row) == 80),
        isTrue,
      );
    });
  });

  group('NO_COLOR degrade (#806 E4)', () {
    test('the band renders shape-only without any SGR', () {
      FaThemeController.instance.profile = null;
      final m = _model(_bandCallbacks());
      final rows = m.view().content.split('\n');
      final gutterRow = _gutterRowIndex(rows);
      expect(gutterRow, greaterThan(0));
      // Band + composer rows carry zero escapes but keep the exact shape:
      // the band is still the width-exact engine render, flush to width.
      expect(_ansi.hasMatch(rows[gutterRow - 1]), isFalse);
      expect(
        rows[gutterRow - 1],
        _engine.render(_snapshot(), m.termWidth).first,
      );
      expect(tuiTextWidth(rows[gutterRow - 1]), m.termWidth);
      expect(_ansi.hasMatch(rows[gutterRow]), isFalse);
      expect(rows[gutterRow], '╰─ ');
    });
  });
}
