@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';

import 'package:test/test.dart';

import 'fa_cli_fixtures.dart';
import 'pty_harness.dart';

/// Shift+Enter / newline wire formats (issue #931 part 3.4: split out of
/// fa_cli_integration_test.dart so the file-level scheduler can run the
/// boot/settings suite and these PTY wire tests concurrently).
void main() {
  group('Fa CLI newline wires', () {
    test(
      'shift+enter inserts a newline (kitty + modifyOtherKeys wires)',
      () async {
        // Shift+Enter reached the CLI three ways depending on the terminal:
        // bare CR (macOS CG poll covers that), the kitty CSI-u encoding, and
        // xterm modifyOtherKeys. dart_tui requests the encodings at startup
        // (CSI =1;1u + modifyOtherKeys=2); this test drives the REAL binary
        // over a PTY and asserts both wire formats land as a newline.
        final tempHome = makeTempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        // The keyboard-enhancement requests went out at startup: this is what
        // makes a supporting terminal actually SEND the disambiguated keys.
        expect(harness.rawOutput, contains('\x1b[=1;1u'));
        expect(harness.rawOutput, contains('\x1b[>4;2m'));

        // kitty keyboard protocol: CSI 13;2 u (Enter + shift modifier).
        await expectNewline(harness, '\x1b[13;2u');
        // xterm modifyOtherKeys: CSI 27;2;13 ~ (shift+enter as a ~-key).
        await expectNewline(harness, '\x1b[27;2;13~');
        // Legacy ESC CR encoding (terminals without protocol support, e.g.
        // Warp's passthrough) — decoded as alt+enter.
        await expectNewline(harness, '\x1b\r');
        // Raw Ctrl+O control byte (0x0F): the universal legacy wire —
        // a plain control character, so it works in EVERY terminal.
        await expectNewline(harness, '\x0f');
      },
    );
    test(
      'shift+enter survives a default-termios PTY (ICRNL on — issue #77)',
      () async {
        // Real PTY hosts (IDE embedded terminals, e.g. yoloit) deliver
        // Shift+Enter as ESC CR, and their default termios has ICRNL on —
        // the kernel line discipline rewrites the CR to LF before fa reads
        // it. fa must clear ICRNL at TUI startup (stty -icrnl) so the ESC CR
        // wire arrives intact; the parser also decodes the translated ESC LF
        // as alt+enter for hosts where stty is unavailable. The raw:true
        // harness above can never see this failure class — this suite runs
        // the same wire matrix against the kernel-default termios.
        final tempHome = makeTempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
          raw: false,
        );
        addTearDown(() async {
          await harness.close();
          tempHome.deleteSync(recursive: true);
        });
        await harness.waitForBoot();

        // The exact yoloit wire: ESC CR, ICRNL rewrites it to ESC LF when
        // fa failed to clear the flag (AC1).
        await expectNewline(harness, '\x1b\r');
        // The translated wire itself (AC2): ESC LF decodes as alt+enter —
        // the fallback for hosts that reset termios under us or where stty
        // is unavailable.
        await expectNewline(harness, '\x1b\n');
        // No regression under ICRNL-on termios (AC4/AC5): protocol wires and
        // the Ctrl+O fallback still insert newlines.
        await expectNewline(harness, '\x1b[13;2u');
        await expectNewline(harness, '\x1b[27;2;13~');
        await expectNewline(harness, '\x0f');

        // Plain Enter still SUBMITS under the default-termios PTY (AC4):
        // /exit closes the REPL — the process must actually go away.
        // runSlashCommand's pauses keep the menu-close Escape and the
        // submitting CR in separate reads (together they would decode as
        // alt+enter — the very wire this test asserts a newline for).
        await harness.runSlashCommand('/exit');
        await harness.pty.exitCode.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'fa did not exit on plain-CR /exit submit',
            const Duration(seconds: 20),
          ),
        );
      },
    );
  });
}

/// Types `a{n}b`, sends [rawKey], types `c{n}d`, and asserts `c{n}d` landed
/// on a row BELOW `a{n}b` (a newline was inserted) without submitting the
/// composer. Each call gets a UNIQUE numeric marker — earlier variants leave
/// stale `a…b`/`c…d` rows on the viewport (and loaded CI runners repaint
/// partial frames), so shared markers make the row measurement race with
/// history; unique markers can only ever match the CURRENT composer render.
/// Backspaces the buffer clean afterwards so variants can share one harness.
///
/// gh-1026: every wait is a bounded POLL on the painted viewport, not a
/// fixed sleep plus a single frame read. On a loaded host the raw echo
/// settles long before the render loop repaints (the #550 family), so the
/// old `waitForOutput(settleMs:)` + immediate `viewportLines` read raced
/// the paint and failed ambient runs. The poller is the same bounded-retry
/// shape `waitForScreen` uses, lifted to a row RELATIONSHIP.
Future<void> expectNewline(FaCliHarness harness, String rawKey) async {
  _newlineVariant++;
  final ab = 'a${_newlineVariant}b';
  final cd = 'c${_newlineVariant}d';
  harness.sendText(ab);
  await _waitForViewport(
    harness,
    '$ab visible in the composer',
    (lines) => lines.lastIndexWhere((l) => l.contains(ab)) >= 0,
  );
  harness.sendText(rawKey);
  harness.sendText(cd);
  await _waitForViewport(
    harness,
    '"$cd" on a row BELOW "$ab" (newline inserted for $rawKey)',
    (lines) {
      // Search from the END of the viewport: the composer re-renders in
      // place as it grows, so a stale earlier frame (with cd already typed
      // but the newline not yet rendered) can sit ABOVE the current one —
      // first-match indexWhere would pin cd to that ghost row.
      final abRow = lines.lastIndexWhere((l) => l.contains(ab));
      if (abRow < 0) return false;
      return lines.lastIndexWhere((l) => l.contains(cd)) > abRow;
    },
  );
  // A frame that fuses ab+cd onto ONE row is the newline never applied —
  // a genuine contract failure (the wire was lost or submitted), asserted
  // only AFTER the newline frame is confirmed so a mid-echo transient
  // frame cannot fail the run.
  expect(
    harness.screenText.contains('$ab$cd'),
    isFalse,
    reason: 'shift+enter submitted instead of newline for $rawKey',
  );
  // Reset the input for the next variant: backspace over the tail, then
  // over the newline and the head (marker-length aware — the variant
  // number widens the markers as it grows).
  for (var i = 0; i < ab.length + cd.length + 1; i++) {
    harness.sendBackspace();
  }
}

/// Bounded poll on the painted viewport until [ready] holds — the
/// gh-1026 replacement for fixed sleeps ahead of frame assertions.
/// Fails with the current screen when the deadline passes.
Future<void> _waitForViewport(
  FaCliHarness harness,
  String description,
  bool Function(List<String> lines) ready,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (ready(harness.viewportLines)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(
    'timed out waiting for $description on the painted viewport:\n'
    '${harness.screenText}',
  );
}

int _newlineVariant = 0;
