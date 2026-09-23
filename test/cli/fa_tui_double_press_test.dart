// Double-press Ctrl+C contract tests (issue #830), split out of
// fa_tui_test.dart to keep it under the repo's 2800-line gate.
//
// The raw/kitty key path drives the model directly; the SIGINT path's
// shared-policy semantics are pinned in sigint_action_test.dart and the
// PTY legs in test/integration/ctrl_c_double_press_test.dart.
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:flutter_agent_harness/src/cli/tui_editor.dart';
import 'package:flutter_agent_harness/src/cli/sigint_action.dart';
import 'package:test/test.dart';

/// A scriptable monotonic clock — see sigint_action_test.dart; the window
/// is elapsed time, never wall-clock gaps.
final class FakeStopwatch implements Stopwatch {
  FakeStopwatch(this._registry) {
    _registry.add(this);
  }

  final List<FakeStopwatch> _registry;
  Duration _elapsed = Duration.zero;
  bool _running = false;

  void advanceAll(Duration d) {
    for (final sw in _registry) {
      if (sw._running) sw._elapsed += d;
    }
  }

  @override
  Duration get elapsed => _elapsed;
  @override
  int get elapsedTicks => _elapsed.inMicroseconds;
  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;
  @override
  int frequency = 1000000;
  @override
  bool get isRunning => _running;
  @override
  void start() => _running = true;
  @override
  void stop() => _running = false;
  @override
  void reset() => _elapsed = Duration.zero;
}

void main() {
  late List<FakeStopwatch> clocks;
  late FakeStopwatch clock;

  setUp(() {
    clocks = [];
    clock = FakeStopwatch(clocks);
  });

  SigintPolicy policy() => SigintPolicy(stopwatch: () => FakeStopwatch(clocks));
  void advance(Duration d) => clock.advanceAll(d);

  FaTuiCallbacks callbacks({
    void Function()? onInterrupt,
    void Function()? onCtrlCExit,
  }) {
    return FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onInterrupt: onInterrupt,
      onCtrlCExit: onCtrlCExit,
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => 'test',
      prompt: 'fa> ',
    );
  }

  FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

  FaTuiModel typed(FaTuiModel m, String text) {
    for (final ch in text.split('')) {
      m = send(m, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
    }
    return m;
  }

  KeyPressMsg ctrl(String ch) => KeyPressMsg(
    TeaKey(code: KeyCode.rune, text: ch, modifiers: {KeyMod.ctrl}),
  );

  test('ctrl+c press 1 interrupts and stays — never a quit', () {
    var interrupted = false;
    final model = FaTuiModel(
      callbacks: callbacks(onInterrupt: () => interrupted = true),
      isExited: () => false,
      sigintPolicy: policy(),
    );
    final (next, cmd) = model.update(ctrl('c'));
    expect(interrupted, isTrue);
    expect((next as FaTuiModel).ctrlCArmed, isTrue, reason: 'footer hint armed');
    expect(cmd, isNotNull, reason: 'press 1 schedules the window expiry');
  });

  test('press 1 schedules the window expiry, not a quit', () async {
    final model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      sigintPolicy: SigintPolicy(
        window: Duration.zero, // the scheduled wait collapses to a tick
        stopwatch: () => FakeStopwatch(clocks),
      ),
    );
    final (_, cmd) = model.update(ctrl('c'));
    final msg = await cmd?.call();
    expect(
      msg,
      isA<CtrlCWindowExpiredMsg>(),
      reason: 'press 1 arms a timed hint, never a quit (#830)',
    );
  });

  group('double-press ctrl+c (issue #830)', () {
    test('press 1 at an idle prompt clears the composer and shows the '
        'dim hint in the footer row', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = typed(model, 'draft text');
      model = send(model, ctrl('c'));
      expect(model.inputText, isEmpty, reason: 'ctrl+c clear');
      expect(model.ctrlCArmed, isTrue);
      expect(model.view().content, contains('press ctrl+c again to exit'));
    });

    test('press 1 clears attachments and closes a stale slash menu', () {
      const chip = TuiImageAttachment(
        name: 'clipboard-3.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      );
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        sigintPolicy: policy(),
        attachments: const [chip],
        editor: TuiLineEditor('half-written', 12),
        menuOpen: true,
        menuTokenStart: 0,
      );
      // SIGINT press 1 arms before mode gating, so the composer must
      // converge to the same cleared state as the key path.
      model = send(model, const InterruptArmedMsg());
      expect(model.inputText, isEmpty);
      expect(model.cursor, 0);
      expect(model.attachments, isEmpty, reason: 'clear resets the composer');
      expect(model.menuOpen, isFalse, reason: 'no stale items under the menu');
      expect(model.menuTokenStart, -1);
    });

    test('press 1 with an empty composer only shows the hint', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = send(model, ctrl('c'));
      expect(model.ctrlCArmed, isTrue);
    });

    test('press 1 while a run streams aborts but keeps the composer', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        busy: true,
        sigintPolicy: policy(),
      );
      model = typed(model, 'queued thought');
      model = send(model, ctrl('c'));
      expect(model.ctrlCArmed, isTrue);
      expect(
        model.inputText,
        'queued thought',
        reason: 'abort owns the screen',
      );
    });

    test('press 2 within the window exits with SIGINT parity', () async {
      var exited = false;
      final model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      final (first, _) = model.update(ctrl('c'));
      final (second, secondCmd) = (first as FaTuiModel).update(ctrl('c'));
      expect((second as FaTuiModel).ctrlCArmed, isFalse);
      await secondCmd?.call();
      expect(exited, isTrue, reason: 'resume hint + exit 130 via the host');
    });

    test('a press after the window is a fresh press 1 (monotonic clock)', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = send(model, ctrl('c')); // press 1 at elapsed=0
      advance(
        kSigintPressWindow + const Duration(milliseconds: 100),
      ); // expired
      model = send(model, ctrl('c')); // fresh press 1 — NOT an exit
      expect(model.ctrlCArmed, isTrue);
    });

    test('the armed hint expires with the window and cannot lie', () async {
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = send(model, ctrl('c')); // press 1: arm
      expect(model.ctrlCArmed, isTrue);
      expect(model.view().content, contains('press ctrl+c again to exit'));

      advance(kSigintPressWindow + const Duration(milliseconds: 100));
      model = send(model, const CtrlCWindowExpiredMsg());
      expect(model.ctrlCArmed, isFalse, reason: 'the hint must not outlive '
          'the window it describes');
      expect(
        model.view().content,
        isNot(contains('press ctrl+c again to exit')),
      );

      // The next press is a fresh press 1 — it must NOT exit…
      model = send(model, ctrl('c'));
      expect(exited, isFalse);
      expect(model.ctrlCArmed, isTrue);
      // …but the press after it, inside the fresh window, does.
      final (next, cmd) = model.update(ctrl('c'));
      await cmd?.call();
      expect(exited, isTrue);
      expect((next as FaTuiModel).ctrlCArmed, isFalse);
    });

    test('any other keypress resets the window and hides the hint', () {
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = send(model, ctrl('c'));
      expect(model.ctrlCArmed, isTrue);
      model = send(
        model,
        KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'x')),
      );
      expect(model.ctrlCArmed, isFalse, reason: 'hint gone on next keypress');
      expect(model.inputText, 'x');
      model = send(model, ctrl('c')); // fresh press 1, not an exit
      expect(exited, isFalse);
      expect(model.ctrlCArmed, isTrue);
    });

    test('a paste between presses resets the window (review: any input)',
        () async {
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: policy(),
      );
      model = send(model, ctrl('c')); // press 1: arm
      expect(model.ctrlCArmed, isTrue);
      model = send(model, PasteMsg('pasted draft'));
      expect(model.ctrlCArmed, isFalse, reason: 'a paste is other input');
      model = send(model, ctrl('c')); // would be press 2 — must NOT exit
      expect(exited, isFalse, reason: 'paste reset the window');
      expect(model.ctrlCArmed, isTrue);
    });

    test('both input paths consume ONE shared policy (ACX.5)', () async {
      // The host (SIGINT) resolves press 1 on the shared policy…
      final shared = policy();
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: shared,
      );
      expect(shared.press(headless: false), SigintAction.interruptAndStay);
      // …so the TUI's very next ctrl+c KEY press is press 2: exit.
      final (next, cmd) = model.update(ctrl('c'));
      await cmd?.call();
      expect(exited, isTrue, reason: 'SIGINT path armed the shared window');
      expect((next as FaTuiModel).ctrlCArmed, isFalse);
    });

    test('press 1 under the hub overlay shows the hint in the hub footer',
        () {
      final hub = FaHubState(
        mode: FaHubMode.tree,
        title: 'agents hub',
        lines: const [],
        hint: 'enter select',
      );
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        sigintPolicy: policy(),
        hub: hub,
      );
      final plain = model.view().content;
      expect(plain, contains('enter select'));
      expect(plain, isNot(contains('press ctrl+c again to exit')));
      model = send(model, ctrl('c')); // press 1 under the overlay
      final armed = model.view().content;
      expect(
        armed,
        contains('press ctrl+c again to exit'),
        reason: 'the composer status row is covered by the overlay',
      );
    });
  });
}
