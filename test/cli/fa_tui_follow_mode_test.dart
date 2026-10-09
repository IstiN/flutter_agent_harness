// The follow-mode contract on the CLI TUI (gh-1439 AC1 + edges E1/E2/E5/
// E6/E7): scrolling up while the agent streams never yanks the user back
// down — PgUp/wheel-up hold the window, arrivals count into the `● N new`
// counter on the reserved rule row, and one action (End key, jump-chip
// click, wheel/PgDn to the near-bottom band) returns to live.
//
// Pure model+render tests — no PTY (same harness as
// fa_tui_viewport_fold_test.dart); the PTY E2E pin rides the existing
// terminal-visual family.
library;

import 'package:dart_tui/dart_tui.dart' hide stripAnsi;

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show stripAnsi;
import 'package:flutter_agent_harness/src/viewport/follow_mode.dart';
import 'package:test/test.dart';

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => '/work · 0tok · turn 0 · test-model',
  prompt: 'fa> ',
);

FaTuiModel _build({int termWidth = 80, int termHeight = 24}) => FaTuiModel(
  callbacks: _callbacks(),
  isExited: () => false,
  termWidth: termWidth,
  termHeight: termHeight,
);

FaTuiModel _send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

List<String> _rowsOf(FaTuiModel m) =>
    m.view().content.split('\n').map((r) => stripAnsi(r)).toList();

final _counter = RegExp(r'● (\d+) new');

int? _unseenOf(List<String> rows) {
  for (final row in rows) {
    final m = _counter.firstMatch(row);
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

/// A model with [n] transcript rows parked at the live edge (one live
/// append snaps the window to the bottom anchor before the user holds).
FaTuiModel filled(int n, {int termHeight = 24}) {
  var model = _build(
    termHeight: termHeight,
  ).copyWith(outputLines: [for (var i = 0; i < n; i++) 'row $i']);
  return _send(model, OutputMsg('seed', newline: true));
}

void main() {
  group('AC1 — PgUp holds through the stream; the counter lives on the '
      'rule row; End returns to live', () {
    test('PgUp holds the fold through 50 append events', () {
      var model = filled(60, termHeight: 24);
      final liveBottom = model.scrollOffset;
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(model.followTail, isFalse, reason: 'PgUp disengages');
      final parked = model.scrollOffset;
      expect(parked, lessThan(liveBottom));

      for (var i = 0; i < 50; i++) {
        model = _send(model, OutputMsg('late $i', newline: true));
      }
      expect(model.followTail, isFalse);
      expect(
        model.scrollOffset,
        parked,
        reason: 'the window never moves under the stream (zero yank)',
      );
      expect(model.follow.unseen, 50, reason: 'every append event counted');
    });

    test('the held rule row grows the live ● N new counter (fold line '
        'extension, open question 3)', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(model, OutputMsg('late 0', newline: true));
      model = _send(model, OutputMsg('late 1', newline: true));
      model = _send(model, OutputMsg('late 2', newline: true));

      final rows = _rowsOf(model);
      final unseen = _unseenOf(rows);
      expect(unseen, 3, reason: 'the counter shows on-screen while held');
      final counterRow = rows.firstWhere((r) => r.contains('● 3 new'));
      expect(
        counterRow.startsWith('────'),
        isTrue,
        reason: 'the counter rides the dim rule row (chrome grammar)',
      );
      expect(
        counterRow,
        contains('%'),
        reason: 'the position rule stays — the counter GROWS it',
      );
      expect(
        counterRow,
        contains('End'),
        reason: 'the one-action re-engage is named on the row',
      );
    });

    test('End jumps to live and flushes the count', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      for (var i = 0; i < 10; i++) {
        model = _send(model, OutputMsg('late $i', newline: true));
      }
      expect(model.follow.unseen, 10);

      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.end)));
      expect(model.followTail, isTrue, reason: 'End re-engages live');
      expect(model.follow.unseen, 0, reason: 'the count flushes');
      expect(
        _rowsOf(model).join('\n'),
        contains('late 9'),
        reason:
            'the window lands at the live edge — the newest arrival is '
            'on the glass',
      );
      expect(_unseenOf(_rowsOf(model)), isNull, reason: 'no counter once live');
    });

    test('End keeps its composer-caret role while the composer has text', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final withText = model.copyWith(inputText: 'draft', cursor: 0);
      final after = _send(
        withText,
        KeyPressMsg(const TeaKey(code: KeyCode.end)),
      );
      expect(
        after.followTail,
        isFalse,
        reason: 'End is the caret key when the composer owns text',
      );
      expect(after.cursor, 'draft'.length);
    });

    test('PgDn past the newest re-arms live without a button (near-bottom '
        're-arm)', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(model, OutputMsg('late 0', newline: true));
      expect(model.followTail, isFalse);

      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(
        model.followTail,
        isTrue,
        reason: 'the page lands inside the near-bottom band',
      );
      expect(model.follow.unseen, 0);
    });

    test('wheel-to-bottom re-arms live; a wheel-up never does', () {
      var model = filled(60);
      model = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.followTail, isFalse);
      model = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelDown)),
      );
      expect(model.followTail, isTrue, reason: 'wheel lands at the bottom');
    });

    test('the counter row is the on-screen jump chip — a click returns to '
        'live', () async {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(model, OutputMsg('late 0', newline: true));
      final rows = _rowsOf(model);
      final counterRowIndex = rows.indexWhere((r) => r.contains('● 1 new'));
      expect(counterRowIndex, greaterThanOrEqualTo(0));

      // The chip row registers a hit region; a release on it re-engages.
      model.view(); // rebuild the per-frame registry
      final (next, _) = model.update(
        MouseClickMsg(
          Mouse(x: 2, y: counterRowIndex, button: MouseButton.left),
        ),
      );
      final (released, _) = (next as FaTuiModel).update(
        MouseReleaseMsg(
          Mouse(x: 2, y: counterRowIndex, button: MouseButton.left),
        ),
      );
      final live = released as FaTuiModel;
      expect(live.followTail, isTrue);
      expect(live.follow.unseen, 0);
    });
  });

  group('AC4 — zero loss: held vs a twin live run', () {
    test('post re-engage the transcript equals the live twin, byte for '
        'byte', () {
      // Twin A: held through 30 arrivals, then End.
      var heldRun = filled(20);
      heldRun = _send(heldRun, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final parked = heldRun.scrollOffset;
      for (var i = 0; i < 30; i++) {
        heldRun = _send(heldRun, OutputMsg('arrive $i', newline: true));
      }
      heldRun = _send(heldRun, KeyPressMsg(const TeaKey(code: KeyCode.end)));

      // Twin B: the same 30 arrivals with the user at the bottom.
      var liveRun = filled(20);
      for (var i = 0; i < 30; i++) {
        liveRun = _send(liveRun, OutputMsg('arrive $i', newline: true));
      }

      expect(
        heldRun.outputLines,
        liveRun.outputLines,
        reason:
            'held mode appends everything — only the viewport '
            'withholds',
      );
      expect(heldRun.follow.unseen, 0);
      expect(heldRun.scrollOffset, greaterThan(parked));
      final rows = _rowsOf(heldRun);
      expect(
        rows.join('\n'),
        contains('arrive 29'),
        reason: 'the newest arrival is on the glass after re-engage',
      );
    });
  });

  group('AC5 — held never persists across restarts', () {
    test('a fresh model (boot/resume) is live at the newest record', () {
      final fresh = _build().copyWith(
        outputLines: [for (var i = 0; i < 60; i++) 'row $i'],
      );
      expect(fresh.follow, const FollowMode.live());
      // The boot window parks at the newest record: the live anchor.
      expect(_rowsOf(fresh).join('\n'), contains('row 59'));
    });

    test('a held model copied for a new run starts the run held-stateless', () {
      // Held state lives on the viewport model instance only — nothing
      // durable carries it (no store, no session field).
      var held = filled(60);
      held = _send(held, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(held.follow.isHeld, isTrue);
      final rebooted = _build().copyWith(
        outputLines: held.outputLines,
        scrollOffset: held.scrollOffset,
      );
      expect(
        rebooted.follow,
        const FollowMode.live(),
        reason: 'a rebooted viewport never restores held',
      );
    });
  });

  group('E1/E2 — the held anchor survives rebuild and resize', () {
    test('E1: a head trim while held keeps the window on the same logical '
        'row (anchored to the transcript line, not the raw offset)', () {
      // 2401 lines: the next append crosses the trim boundary and cuts
      // head lines (the compaction-fold rebuild shape).
      var model = _build().copyWith(
        outputLines: [for (var i = 0; i < 2400; i++) 'pad $i', 'TAIL-MARK'],
      );
      // Park at the live edge first, then hold mid-transcript — the trim
      // must not shift what the user is reading.
      model = _send(model, OutputMsg('seed', newline: true));
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final visibleBefore = _rowsOf(model).take(19).join('\n');

      model = _send(model, OutputMsg('tick', newline: true));
      expect(model.followTail, isFalse);
      final visibleAfter = _rowsOf(model).take(19).join('\n');
      expect(
        visibleBefore,
        visibleAfter,
        reason:
            'the window re-anchors to the same transcript line — the '
            'head trim must not shift what the user is reading',
      );
    });

    test('E1 (re-review): a trim while held with variable-height lines '
        'keeps the exact reading row — offset = anchor row − rows the '
        'dropped head consumed, not the old cache read at the shifted '
        'line', () {
      // Heterogeneous wrapped heights (200-char lines every 7th entry
      // wrap at 80 cols; pads are single rows): with uniform heights the
      // wrong derivation — indexing the PRE-trim wrap cache at the
      // shifted line — coincides with the correct row, which is why the
      // original E1 test passed vacuously (its trim fired before the
      // hold, so cut was always 0).
      final lines = <String>[
        for (var i = 0; i < 1999; i++)
          i % 7 == 0 ? 'LONG $i ${'x' * 200}' : 'pad $i',
        '',
      ];
      var model = _build().copyWith(outputLines: lines);
      model = _send(model, OutputMsg('seed', newline: true));
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final visibleBefore = _rowsOf(model).take(19).join('\n');

      // One burst crosses the 2400-line cap while held: the trim drops
      // head lines (cut > 0) in the SAME append the reader is held
      // through.
      model = _send(
        model,
        OutputMsg(
          [for (var i = 0; i < 500; i++) 'burst $i'].join('\n'),
          newline: true,
        ),
      );
      expect(model.followTail, isFalse);
      final visibleAfter = _rowsOf(model).take(19).join('\n');
      expect(
        visibleAfter,
        visibleBefore,
        reason:
            'the trim must not shift what the user is reading: the '
            'window re-anchors to the anchor line\'s row minus the rows '
            'the dropped head consumed',
      );
    });

    test('E2: resize mid-hold recomputes the same logical position', () {
      var model = filled(60, termHeight: 24);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final topLineBefore = _topVisibleLine(model);

      model = _send(model, WindowSizeMsg(80, 12));
      expect(model.followTail, isFalse, reason: 'resize keeps the hold');
      expect(
        _topVisibleLine(model),
        topLineBefore,
        reason:
            'the window tops out at the same transcript line at the '
            'new size',
      );
    });
  });

  group('E5/E6 — notices count; re-arm is gesture-only', () {
    test('steering-notice appends while held are counted, never shown by '
        'force', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(
        model,
        OutputMsg('⏺ steering notice: context updated', newline: true),
      );
      expect(model.follow.unseen, 1);
      expect(model.followTail, isFalse);
    });

    test('settle cards while held count the same way', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(
        model,
        OutputMsg('── run settled · 1.2s ──\n── next ──', newline: true),
      );
      expect(model.follow.unseen, 1);
      expect(model.followTail, isFalse);
    });

    test('a programmatic viewport move never re-arms (E6 debounce)', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(model, OutputMsg('late 0', newline: true));
      // The stream/resize path clamps the offset without classifying a
      // gesture — held survives a resize that lands the window near the
      // new bottom.
      model = _send(model, WindowSizeMsg(80, 60));
      expect(
        model.followTail,
        isFalse,
        reason:
            'only the user gesture re-arms — never a programmatic '
            'position',
      );
    });
  });

  group('E7 — mouse modes', () {
    test('native-selection mode: wheel does nothing, explicit PgUp '
        'disengages (documented contract)', () {
      var model = filled(60).copyWith(mouseCapture: false);
      final afterWheel = _send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(
        afterWheel.followTail,
        isTrue,
        reason:
            'native mode keeps the mouse for selection — only an '
            'explicit PgUp disengages',
      );
      final afterPgUp = _send(
        afterWheel,
        KeyPressMsg(const TeaKey(code: KeyCode.pageUp)),
      );
      expect(afterPgUp.followTail, isFalse);
      expect(afterPgUp.follow.isHeld, isTrue);
    });
  });

  group('AC6 — approval prompts never wait behind follow mode', () {
    test('the prompt zone renders while held and the counter stays', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      model = _send(model, OutputMsg('late 0', newline: true));
      const request = ApprovalRequest(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: {'command': 'rm -rf build/'},
        reason: 'exec tier requires approval in mode: code',
      );
      final heldModel = model.copyWith(
        prompt: TuiPromptState(ApprovalPromptSpec(request: request)),
      );
      final rows = _rowsOf(heldModel);
      expect(
        rows.join('\n'),
        contains('rm -rf build/'),
        reason:
            'the approval prompt renders at its own rules — follow '
            'mode never delays it',
      );
      expect(
        _unseenOf(rows),
        1,
        reason: 'the held counter keeps counting beside the prompt',
      );
    });
  });

  group('REG — live auto-follow is byte-identical when the user never '
      'scrolls', () {
    test('50 arrivals with no user scroll keep following the live edge; '
        'no counter ever shows', () {
      var model = filled(20);
      final startOffset = model.scrollOffset;
      for (var i = 0; i < 50; i++) {
        model = _send(model, OutputMsg('live $i', newline: true));
      }
      expect(model.followTail, isTrue);
      expect(model.follow.unseen, 0);
      expect(
        model.scrollOffset,
        greaterThan(startOffset),
        reason: 'the live edge advanced with every append',
      );
      expect(
        _rowsOf(model).join('\n'),
        contains('live 49'),
        reason: 'the window rides the live edge',
      );
      expect(_unseenOf(_rowsOf(model)), isNull);
    });

    test('held with zero arrivals keeps the plain percent rule', () {
      var model = filled(60);
      model = _send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final rows = _rowsOf(model);
      expect(_unseenOf(rows), isNull);
      expect(rows.join('\n'), contains('%'));
    });
  });
}

/// The first transcript line visible at the top of the held window (the
/// logical anchor E1/E2 preserve).
String? _topVisibleLine(FaTuiModel m) {
  for (final row in _rowsOf(m)) {
    final match = RegExp(r'^(?:row|pad) (\d+)$').firstMatch(row.trim());
    if (match != null) return row.trim();
  }
  return null;
}
