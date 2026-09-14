@TestOn('vm')
/// Issue #355 — the Shift+Enter HID gate. The gating predicate and the
/// resolver are pure Dart; the probe seam takes a substitute isolate
/// entry, so the hang shape (an SSH session where CoreGraphics never
/// answers) is exercised for real — spawn, bounded timeout, kill.
library;

import 'package:flutter_agent_harness/src/cli/shift_hid.dart';
import 'package:test/test.dart';

void main() {
  group('hidShiftPollingEnabled (gate predicate)', () {
    test('a clean GUI-session env allows the poll', () {
      expect(hidShiftPollingEnabled({}), isTrue);
    });

    test('SSH_CONNECTION marks the session hostile', () {
      expect(hidShiftPollingEnabled({'SSH_CONNECTION': '1 2 3 4'}), isFalse);
    });

    test('SSH_TTY alone marks the session hostile', () {
      expect(hidShiftPollingEnabled({'SSH_TTY': '/dev/ttys004'}), isFalse);
    });

    test('FA_TUI_SHIFT_HID=0 is a kill switch even in a GUI session', () {
      expect(hidShiftPollingEnabled({'FA_TUI_SHIFT_HID': '0'}), isFalse);
    });

    test('falsy spellings mirror the FA_TUI_MOUSE switch', () {
      for (final value in ['0', 'false', 'no', 'off', ' OFF ']) {
        expect(
          hidShiftPollingEnabled({'FA_TUI_SHIFT_HID': value}),
          isFalse,
          reason: 'FA_TUI_SHIFT_HID=$value must disable the poll',
        );
      }
      expect(hidShiftPollingEnabled({'FA_TUI_SHIFT_HID': '1'}), isTrue);
    });
  });

  group('resolveHidShiftPressed', () {
    test('a non-macOS host never wires the poll', () async {
      final poll = await resolveHidShiftPressed(
        env: {},
        isMacOS: false,
        probeEntry: (port) => port.send(true),
      );
      expect(poll, isNull);
    });

    test('an SSH session never wires the poll and spawns no probe', () async {
      var probed = false;
      final poll = await resolveHidShiftPressed(
        env: {'SSH_TTY': '/dev/ttys004'},
        probeEntry: (port) {
          probed = true;
          port.send(true);
        },
      );
      expect(poll, isNull);
      expect(probed, isFalse, reason: 'the gate must short-circuit SSH');
    });

    test('the kill switch wins even on a GUI-session macOS host', () async {
      final poll = await resolveHidShiftPressed(
        env: {'FA_TUI_SHIFT_HID': '0'},
        probeEntry: (port) => port.send(true),
      );
      expect(poll, isNull);
    });

    test('a healthy probe wires the poll', () async {
      final poll = await resolveHidShiftPressed(
        env: {},
        probeEntry: (port) => port.send(true),
      );
      expect(poll, isNotNull);
    });

    test('a probe answering false leaves the poll unwired', () async {
      final poll = await resolveHidShiftPressed(
        env: {},
        probeEntry: (port) => port.send(false),
      );
      expect(poll, isNull);
    });

    test('a hanging probe times out bounded and disables the poll', () async {
      final watch = Stopwatch()..start();
      final poll = await resolveHidShiftPressed(
        env: {},
        probeEntry: (_) {}, // never answers — the SSH freeze shape
        probeTimeout: const Duration(milliseconds: 100),
      );
      watch.stop();
      expect(poll, isNull, reason: 'a wedged CoreGraphics read must gate off');
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'startup must never wait on a hung probe',
      );
    });
  });

  test('a probe isolate that never answers is killed, not leaked', () async {
    // Completing at all is the assertion: the timeout fires and the
    // finally block kills the wedged isolate instead of leaking it.
    final ok = await probeHidShiftPolling(
      entry: (_) {},
      timeout: const Duration(milliseconds: 100),
    );
    expect(ok, isFalse);
  });

  test('the default probe answers from the real HID read bounded', () async {
    // False wherever CoreGraphics is unavailable (every CI host); a live
    // GUI-session macOS host answers with the actual Shift state.
    final ok = await probeHidShiftPolling(timeout: const Duration(seconds: 2));
    expect(ok, isA<bool>());
  });
}
