import 'dart:async';

import 'package:dart_tui/dart_tui.dart';
import 'package:test/test.dart';

import 'support/string_sink.dart';

// Issue #1977 — resize-invariant TUI rendering: a terminal geometry change
// must force ONE full repaint of the new grid on the next frame, regardless
// of diff economics (a cell diff against the previous-geometry grid leaves
// coordinate-matched stale bytes in the bottom band). The routing under
// test: SIGWINCH → WindowSizeMsg → Program.applyMsg → renderer.invalidate()
// → next render() takes the first-frame path. These pins drive a REAL
// Program + CellRenderer headlessly (no PTY) and assert on the raw escape
// stream.
const _content = 'aaaa\nbbbb\ncccc\ndddd';

const _fullRepaintFrame = '\x1b[1;1H\x1b[K'
    '\x1b[2;1H\x1b[K'
    '\x1b[3;1H\x1b[K'
    '\x1b[4;1H\x1b[K'
    '\x1b[1;1Haaaa\x1b[2;1Hbbbb\x1b[3;1Hcccc\x1b[4;1Hdddd';

// Sizes that can never collide with the piped-stdout 80×24 default the
// startup WindowSizeMsg reports under `dart test`.
final _wide = WindowSizeMsg(113, 37);
final _narrow = WindowSizeMsg(97, 31);
final _wider = WindowSizeMsg(137, 41);

final class _FrameSyncModel extends Model {
  Cursor? cursor;

  Completer<void>? _framePainted;

  @override
  Cmd? init() => null;

  @override
  (Model, Cmd?) update(Msg msg) => (this, null);

  @override
  View view() {
    _framePainted?.complete();
    _framePainted = null;
    return View(content: _content, cursor: cursor);
  }

  /// Resolves when the next frame after this call is painted.
  Future<void> nextFrame() {
    final c = Completer<void>();
    _framePainted = c;
    return c.future.timeout(const Duration(seconds: 2));
  }
}

Future<(_FrameSyncModel, Program, Future<void>)> _boot(TestSink sink) async {
  final model = _FrameSyncModel();
  final program = Program(options: [
    withOutput(sink),
    withInput(null),
    withCellRenderer(),
  ]);
  // Arm before run(): the event loop may paint the first frame without
  // ever yielding to this microtask chain.
  final painted = model.nextFrame();
  final run = program.run(model);
  await painted;
  return (model, program, run);
}

void main() {
  // AC1 + AC2: after a geometry change, a byte-identical frame must still
  // take the full-repaint path — per-row clears + every row rewritten. The
  // pre-fix behavior (diff against the previous-geometry grid, or the
  // content-identical early return) emits ZERO bytes here.
  test('changed geometry repaints identical content as the first frame',
      () async {
    final sink = TestSink();
    final (model, program, run) = await _boot(sink);
    addTearDown(() async {
      program.kill();
      await run;
    });
    sink.buf.clear();

    program.send(_wide);
    await model.nextFrame();

    expect(sink.buf.toString(), _fullRepaintFrame);
  });

  // I2 / edge case: a WindowSizeMsg reporting UNCHANGED geometry is a
  // no-op — the diff economy of #274 stays intact (zero-byte idle frame).
  test('same-geometry WindowSizeMsg emits nothing', () async {
    final sink = TestSink();
    final (model, program, run) = await _boot(sink);
    addTearDown(() async {
      program.kill();
      await run;
    });

    program.send(_wide);
    await model.nextFrame();
    sink.buf.clear();

    program.send(WindowSizeMsg(_wide.width, _wide.height));
    await model.nextFrame();

    expect(sink.buf.toString(), '');
  });

  // AC4: the cursor position after a resize is re-homed from the NEW
  // grid — the repaint path re-emits the CUP even when the logical cursor
  // coordinates are unchanged (a skipped/diffed frame would leave the
  // physical cursor wherever the previous frame's writes ended).
  test('cursor after resize re-homes to the new grid position', () async {
    final sink = TestSink();
    final (model, program, run) = await _boot(sink);
    addTearDown(() async {
      program.kill();
      await run;
    });
    model.cursor = const Cursor(x: 2, y: 1);
    program.send(_wide);
    await model.nextFrame();
    sink.buf.clear();

    // Geometry changes again, the cursor does NOT: only a true full
    // repaint (forceHome) may re-address the physical cursor.
    program.send(_wider);
    await model.nextFrame();

    expect(sink.buf.toString(), endsWith('\x1b[2;3H'));
  });

  // AC6 REG shield: narrow → wide → narrow with a coordinate-identical
  // bottom band — every step of the sequence must full-repaint; a diff
  // against the previous-geometry grid would skip the identical band and
  // leave stale bytes.
  test('narrow → wide → narrow full-repaints on every geometry change',
      () async {
    final sink = TestSink();
    final (model, program, run) = await _boot(sink);
    addTearDown(() async {
      program.kill();
      await run;
    });

    for (final size in [_narrow, _wider, _narrow]) {
      sink.buf.clear();
      program.send(size);
      await model.nextFrame();
      expect(sink.buf.toString(), _fullRepaintFrame,
          reason: 'resize to ${size.width}×${size.height} must repaint '
              'every row');
    }
  });
}
