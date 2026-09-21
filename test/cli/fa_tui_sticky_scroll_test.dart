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

import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart';
import 'package:dart_tui/src/renderer.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

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

  test('streaming under the pinned sticky echo never scrolls the screen', () {
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
    final rows = model
        .view()
        .content
        .split('\n')
        .map((l) => l.replaceAll(ansi, ''))
        .toList();
    expect(rows.first, '─' * 80, reason: 'sticky echo pins the frame top');
    expect(rows[1], contains('explain the scrollback bug'));

    // Feed eleven consecutive streaming frames through the real renderer.
    final buf = StringBuffer();
    final renderer = CellRenderer(
      output: _BufSink(buf),
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
      reason:
          'row 0 stays pinned while streaming — a whole-screen scroll '
          'would push the prompt echo into the terminal scrollback (#761)',
    );

    // Replay what a terminal would have shown: the live screen converges to
    // the streamed tail, and the native scrollback receives NO copy of the
    // pinned prompt (pre-fix, one scrolled-off copy per frame).
    final replay = _replay(out, rows: 80, cols: 80);
    expect(replay.screen, contains('answer line 39'));
    expect(
      replay.scrollback,
      isNot(contains('explain the scrollback bug')),
      reason: 'the sticky echo must stay pinned, never scroll off',
    );
  });
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
    final osc = RegExp(
      r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)',
    ).matchAsPrefix(bytes, i);
    if (osc != null) {
      i = osc.end;
      continue;
    }
    final esc = RegExp(
      r'\x1b(\[[0-9;?<>=]*[A-Za-z]|.)',
    ).matchAsPrefix(bytes, i);
    i = esc?.end ?? i + 1;
  }
  return _Replay(
    screen.map((row) => row.join().trimRight()).join('\n'),
    scrollback.join('\n'),
  );
}

/// Minimal [IOSink] over a [StringBuffer] capturing what the renderer would
/// write to the tty.
final class _BufSink implements IOSink {
  _BufSink(this._buf);
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
