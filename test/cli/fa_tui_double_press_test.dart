// Double-press Ctrl+C contract tests (issue #830), split out of
// fa_tui_test.dart to keep it under the repo's 2800-line gate.
//
// The raw/kitty key path drives the model directly; the SIGINT path's
// shared-policy semantics are pinned in sigint_action_test.dart and the
// PTY legs in test/integration/ctrl_c_double_press_test.dart.
import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/sigint_action.dart';
import 'package:test/test.dart';

void main() {
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

  test('ctrl+c press 1 interrupts and stays — no quit command', () {
    var interrupted = false;
    final model = FaTuiModel(
      callbacks: callbacks(onInterrupt: () => interrupted = true),
      isExited: () => false,
    );
    final result = model.update(ctrl('c'));
    expect(interrupted, isTrue);
    expect(
      (result.$1 as FaTuiModel).ctrlCArmed,
      isTrue,
      reason: 'footer hint armed',
    );
    expect(result.$2, isNull, reason: 'press 1 never quits (issue #830)');
  });

  group('double-press ctrl+c (issue #830)', () {
    test('press 1 at an idle prompt clears the composer and shows the '
        'dim hint in the footer row', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'draft text');
      model = send(model, ctrl('c'));
      expect(model.inputText, isEmpty, reason: 'ctrl+c clear');
      expect(model.ctrlCArmed, isTrue);
      expect(model.view().content, contains('press ctrl+c again to exit'));
    });

    test('press 1 with an empty composer only shows the hint', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = send(model, ctrl('c'));
      expect(model.ctrlCArmed, isTrue);
    });

    test('press 1 while a run streams aborts but keeps the composer', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        busy: true,
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
      );
      final (first, firstCmd) = model.update(ctrl('c'));
      expect(firstCmd, isNull);
      final (second, secondCmd) = (first as FaTuiModel).update(ctrl('c'));
      expect((second as FaTuiModel).ctrlCArmed, isFalse);
      await secondCmd?.call();
      expect(exited, isTrue, reason: 'resume hint + exit 130 via the host');
    });

    test('a press after the window is a fresh press 1 (injected clock)', () {
      var clockMs = 0;
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(clockMs);
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        now: clock,
      );
      model = send(model, ctrl('c')); // press 1 at t=0
      clockMs = 3100; // window (3s) expired
      model = send(model, ctrl('c')); // fresh press 1 — NOT an exit
      expect(model.ctrlCArmed, isTrue);
    });

    test('any other keypress resets the window and hides the hint', () {
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
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

    test('both input paths consume ONE shared policy (ACX.5)', () async {
      var clockMs = 0;
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(clockMs);
      // The host (SIGINT) resolves press 1 on the shared policy…
      final policy = SigintPolicy(now: clock);
      var exited = false;
      var model = FaTuiModel(
        callbacks: callbacks(onCtrlCExit: () => exited = true),
        isExited: () => false,
        sigintPolicy: policy,
        now: clock,
      );
      expect(policy.press(headless: false), SigintAction.interruptAndStay);
      // …so the TUI's very next ctrl+c KEY press is press 2: exit.
      final (next, cmd) = model.update(ctrl('c'));
      await cmd?.call();
      expect(exited, isTrue, reason: 'SIGINT path armed the shared window');
      expect((next as FaTuiModel).ctrlCArmed, isFalse);
    });

    test('SIGINT press 1 routes through InterruptArmedMsg and clears the '
        'idle composer', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'half-written');
      model = send(model, const InterruptArmedMsg());
      expect(model.inputText, isEmpty);
      expect(model.ctrlCArmed, isTrue);
      expect(model.view().content, contains('press ctrl+c again to exit'));
    });
  });
}
