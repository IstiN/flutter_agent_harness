// Sticky echo + whole-screen scroll corruption (issue #761): while a run
// streams, FaTuiModel pins the user prompt to row 0 (_writeStickyEcho) and
// the tail-follow advances history beneath it. The CellRenderer's tolerant
// scroll detector matched those frames as whole-screen scrolls and emitted
// `CSI S`, pushing a copy of the pinned prompt into the terminal's native
// scrollback every frame (the user saw the prompt repeated 12 times while
// the scrolled-away middle of the answer never reached the scrollback).
//
// Pure renderer+model frames — no PTY: the Fa view is fed through the real
// CellRenderer over an in-memory sink, and the emitted bytes are replayed
// on a tiny terminal model (the same approach as the vendored renderer
// tests) so the assertions see what a real terminal would show.
library;


import 'package:dart_tui/dart_tui.dart';
import 'package:dart_tui/src/renderer.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_chrome.dart' show tuiChromeEnabled;
import 'package:test/test.dart';

import 'tui_render_harness.dart';

void main() {
  FaTuiCallbacks callbacks() => FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => '',
    prompt: '',
  );

  FaTuiModel send(FaTuiModel model, Msg msg) =>
      model.update(msg).$1 as FaTuiModel;

  final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

  for (final chrome in [true, false]) {
    test('streaming under the pinned sticky echo never scrolls the screen '
        '(chrome=$chrome)', () {
      addTearDown(() => tuiChromeEnabled = true);
      tuiChromeEnabled = chrome;
    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 80,
      termHeight: 80,
    );

    // Submit a question: busy starts, the echo is recorded, viewport snaps
    // to the bottom — the real _applySubmit path, not hand-built state.
    model = model.copyWith(inputText: 'explain the scrollback bug');
    model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    // The run lifecycle flips busy via BusyMsg (the submit Cmd's stream);
    // in-app it arrives right after submit — deliver it directly here.
    model = send(model, const BusyMsg(true, source: 'run'));
    expect(model.busy, isTrue, reason: 'submit must start a run');

    // Stream past the viewport height so the echo fully scrolls out and the
    // sticky pins; then keep streaming — like real streamed text, each
    // message advances the history by exactly one wrapped row under the
    // pinned rows (the reported corruption shape).
    for (var i = 0; i < 30; i++) {
      model = send(model, OutputMsg('answer line $i', newline: true));
    }

    // Guard against a vacuous pass: the echo must actually be pinned now.
    final rows =
        model.view().content.split('\n').map((l) => l.replaceAll(ansi, '')).toList();
    if (chrome) {
      expect(rows.first.trim(), isEmpty,
          reason: 'sticky echo pins the bubble band top (issue #807 chrome)');
    } else {
      // Kill switch (D1): the legacy full-width dim rule pins row 0.
      expect(rows.first, contains('─'),
          reason: 'tuiChromeEnabled=false keeps the legacy echo rule');
    }
    expect(rows[1], contains('explain the scrollback bug'));

    // Feed eleven consecutive streaming frames through the real renderer.
    final buf = StringBuffer();
    final renderer = CellRenderer(
      output: StringSinkIOSink(buf),
      logSink: null,
      defaultAltScreen: false,
      defaultHideCursor: false,
    );
    renderer.render(model.view());
    for (var i = 30; i < 40; i++) {
      model = send(model, OutputMsg('answer line $i', newline: true));
      renderer.render(model.view());
    }
    final out = buf.toString();

    expect(
      RegExp(r'\x1b\[[0-9]*S').hasMatch(out),
      isFalse,
      reason: 'row 0 stays pinned while streaming — a whole-screen scroll '
          'would push the prompt echo into the terminal scrollback (#761)',
    );

    // Replay what a terminal would have shown: the live screen converges to
    // the streamed tail, and the native scrollback receives NO copy of the
    // pinned prompt (pre-fix, one scrolled-off copy per frame).
    final replay = _replay(out, rows: 80, cols: 80);
    expect(replay.screen, contains('answer line 39'));
    expect(replay.scrollback, isNot(contains('explain the scrollback bug')),
        reason: 'the sticky echo must stay pinned, never scroll off');
  });
  }

  // Wrap-turn dedupe (issue #917): the pin-vs-transcript decision used the
  // RAW stored scroll offset while the frame paints at the freshly computed
  // follow bottom. Keystrokes re-wrap the input zone between output events
  // (the painted window moves, the stored offset does not), so a slow-PTY
  // backspace burst landing after the last streamed line dropped the window
  // top back below the echo while the pin stayed on: the same turn row
  // painted twice (pinned AND in the transcript).
  //
  // Geometry (termHeight 24, classic chrome: 6 fixed rows → 18 history
  // rows): prior turns + echo put the echo TEXT at window row 3 and its
  // end past row 6 (chrome) / 5 (legacy, the dim rule merges nothing here
  // — both counts land the text at 3). A draft of D wrapped rows shrinks
  // history to 18-(D-1); the streamed sync then stores offset ≥ echo end
  // while D-1 ≥ echo rows above the text, and deleting the draft drops the
  // painted window top back ONTO the text row — pre-fix: pin still on.
  for (final chrome in [true, false]) {
    // A draft of 8 wrapped rows steals 7 history rows: the streamed sync
    // (draft present) stores an offset past the echo end; deleting the
    // draft grows the window back but the pin reclaims 2 of the rows, so
    // the painted top lands exactly on the echo text while the stored
    // offset still says the echo is above the window.
    const draftRows = 8;
    // chrome's bubble echo block is one line taller than the legacy rule
    // echo - the same dup geometry lands one streamed line earlier.
    final answers = chrome ? 11 : 12;

    // Shared #917 fixture (review round 2): builds the synced state both
    // scenarios branch from - submitted echo, streamed answers, an
    // 8-row wrapped draft typed mid-run, one streamed line landing with
    // the draft present (the stored offset syncs past the echo end).
    (FaTuiModel, String) syncedFixture() {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termWidth: 80,
        termHeight: 24,
        outputLines: const ['older line one', 'older line two', ''],
      );
      model = model.copyWith(inputText: 'the racy prompt row');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      model = send(model, const BusyMsg(true, source: 'run'));
      expect(model.busy, isTrue, reason: 'submit must start a run');
      for (var i = 0; i < answers; i++) {
        model = send(model, OutputMsg('answer line $i', newline: true));
      }
      final draft = ('loremipsum ' * (7 * draftRows)).trim();
      for (final ch in draft.split('')) {
        model = send(model, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
      }
      model = send(model, OutputMsg('answer line $answers', newline: true));
      return (model, draft);
    }

    List<String> rowsOf(FaTuiModel model) => model.view().content
        .split('\n')
        .map((l) => l.replaceAll(ansi, ''))
        .toList();

    int paintsOf(FaTuiModel model) =>
        rowsOf(model).where((l) => l.contains('the racy prompt row')).length;

    test('deleting a wrapped draft mid-run never duplicates the pinned '
        'echo (chrome=$chrome, #917)', () {
      addTearDown(() => tuiChromeEnabled = true);
      tuiChromeEnabled = chrome;
      var (model, draft) = syncedFixture();

      // Fixture guard: never a duplicate through every state so far (the
      // pre-fix lost-echo transient - echo neither pinned nor painted -
      // is the sibling raw-offset artifact; the dup is what #917 pins).
      expect(paintsOf(model), lessThanOrEqualTo(1),
          reason: 'fixture: no duplicate while composing');

      // The draft goes away (a backspace burst lands after the last output
      // event - the slow-PTY interleave): the input zone shrinks, the
      // window top drops back onto the echo text, while the stored offset
      // - and with it the pre-fix pin decision - still says the echo is
      // above the window. One paint must win, deterministically.
      for (var i = 0; i < draft.length; i++) {
        model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      }
      expect(paintsOf(model), 1, reason: 'the turn row paints exactly once - '
          'pinned OR in the transcript window, never both');
    });

    // The DETACHED branch of the same dedupe (review round 1): after a
    // PageUp the stored offset IS the painted anchor, and the clamp must
    // stay valid when the window outgrows the transcript — the pre-fix
    // raw negative anchor (wrapped - history + pin < 0) threw
    // ArgumentError inside the plan and killed the frame mid-run.
    test('detached follow never double-paints the echo nor crashes on '
        'a tall window (chrome=$chrome, #917)', () {
      addTearDown(() => tuiChromeEnabled = true);
      tuiChromeEnabled = chrome;
      var (model, draft) = syncedFixture();

      // PageUp mid-run: follow detaches, the stored offset (now the
      // painted anchor) sits above the echo end — the transcript owns
      // the echo, the pin stays off, exactly one paint.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(model.followTail, isFalse, reason: 'pageUp detaches follow');
      expect(paintsOf(model), 1, reason: 'detached: transcript owns the echo');

      // The same slow-PTY backspace burst, detached.
      for (var i = 0; i < draft.length; i++) {
        model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      }
      expect(paintsOf(model), 1, reason: 'detached: still exactly one paint');

      // Then the terminal grows mid-run: the transcript is now SHORTER
      // than the painted window — pre-fix the anchor went negative and
      // the detached clamp threw ArgumentError, killing the frame.
      model = send(model, WindowSizeMsg(80, 80));
      expect(paintsOf(model), 1, reason: 'tall window: one paint, no crash');
    });
  }
}

final class _Replay {
  _Replay(this.screen, this.scrollback);
  final String screen;
  final String scrollback;
}

/// Minimal terminal emulator: CUP, EL, SU/SD and printable characters —
/// enough to observe where the renderer's bytes land. Every printable is
/// one cell (all fixture content is narrow-on-western-terminals).
_Replay _replay(String bytes, {required int rows, required int cols}) {
  var screen = List.generate(rows, (_) => List.filled(cols, ' '));
  final scrollback = <String>[];
  var r = 0;
  var c = 0;
  var i = 0;
  while (i < bytes.length) {
    if (bytes.codeUnitAt(i) != 0x1b) {
      screen[r][c] = bytes[i];
      c = (c + 1).clamp(0, cols - 1);
      i++;
      continue;
    }
    final cup = RegExp(r'\x1b\[(\d*);(\d*)H').matchAsPrefix(bytes, i);
    if (cup != null) {
      r = (int.tryParse(cup.group(1)!) ?? 1) - 1;
      c = (int.tryParse(cup.group(2)!) ?? 1) - 1;
      i = cup.end;
      continue;
    }
    final el = RegExp(r'\x1b\[K').matchAsPrefix(bytes, i);
    if (el != null) {
      for (var j = c; j < cols; j++) {
        screen[r][j] = ' ';
      }
      i = el.end;
      continue;
    }
    final su = RegExp(r'\x1b\[(\d*)S').matchAsPrefix(bytes, i);
    if (su != null) {
      final n = int.tryParse(su.group(1)!) ?? 1;
      scrollback.addAll(screen.take(n).map((row) => row.join().trimRight()));
      screen = [
        ...screen.skip(n),
        for (var j = 0; j < n; j++) List.filled(cols, ' '),
      ];
      i = su.end;
      continue;
    }
    final sd = RegExp(r'\x1b\[(\d*)T').matchAsPrefix(bytes, i);
    if (sd != null) {
      final n = int.tryParse(sd.group(1)!) ?? 1;
      screen = [
        for (var j = 0; j < n; j++) List.filled(cols, ' '),
        ...screen.take(rows - n),
      ];
      i = sd.end;
      continue;
    }
    // SGR, mode sets, OSC 8 and any other escape run is layout-neutral.
    final osc = RegExp(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)').matchAsPrefix(bytes, i);
    if (osc != null) {
      i = osc.end;
      continue;
    }
    final esc = RegExp(r'\x1b(\[[0-9;?<>=]*[A-Za-z]|.)').matchAsPrefix(bytes, i);
    i = esc?.end ?? i + 1;
  }
  return _Replay(screen.map((row) => row.join().trimRight()).join('\n'),
      scrollback.join('\n'));
}
