// AC3 (issue #467): PTY proof for the composer wrap + zero artifacts.
//
// The owner scenario, reproduced on a live PTY: a fake long turn streams
// (mock LLM scripts an 8-second `bash sleep` tool call) while the test
// types a 200-char line into the composer. The screen must show the FULL
// line soft-wrapped across rows, the first character at a row start, the
// cursor at the true end, and ZERO artifact cells — no foreign rows from
// other frames bleeding into the composer region, no stray fragments at
// row ends (the stale "heredoc row + stray digit" evidence class).
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('AC3: typing a 200-char line mid-run wraps fully with zero artifacts',
      () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_tui_467_');
    final server = await MockLlmServer.start()
      ..enqueueToolCall('bash', '{"command": "sleep 15"}')
      ..enqueueText('sleep finished');
    addTearDown(server.stop);
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');

    final harness = await FaCliHarness.spawn(
      extraEnv: {'HOME': tempHome.path},
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    await harness.waitForBoot();

    // Start the fake long turn: the scripted tool call keeps the busy row
    // alive for ~15 s — the exact window the owner typed into.
    final harnessSendText = harness.sendText;
    harnessSendText('run the long sleep now');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    harness.sendEnter();
    await harness.waitForText('· submit', timeout: const Duration(seconds: 20));

    // Mid-run: compose a 200-char line of prose (like the owner's). Greedy
    // word wrap at 80 cells packs rows 76 + 79 + 43 cells.
    const text =
        'please check whether the composer wraps this very long line '
        'correctly across several terminal rows without ever sliding the '
        'beginning of the sentence out of view at any point during a long '
        'busy run ok';
    expect(text.length, 200);
    // Typing bursts of ~10 chars — real keystroke cadence, not a paste.
    for (var i = 0; i < text.length; i += 10) {
      harnessSendText(text.substring(i, i + 10 > text.length
          ? text.length
          : i + 10));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Let several 1 Hz busy ticks repaint the frame over the composition.
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    final rows = [
      for (final line in harness.viewportLines) line.trimRight(),
    ];
    final rule = '─' * 80;
    final rules = <int>[
      for (var i = 0; i < rows.length; i++)
        if (rows[i].trim() == rule) i,
    ];
    expect(rules.length, greaterThanOrEqualTo(2), reason: 'input zone frame');
    final region = rows.sublist(rules[rules.length - 2] + 1, rules.last);

    // The busy row really is on screen (we are mid-run) — accept any live
    // label: generic 'Working…' or the phase label ('Running bash…').
    expect(
      rows.take(rules[rules.length - 2]).any(
        (l) =>
            l.contains('Working') ||
            l.contains('Running') ||
            l.contains('· submit'),
      ),
      isTrue,
      reason: 'the fake turn must still be running; screen:\n'
          '${rows.take(rules[rules.length - 2] + 1).join("\n")}',
    );

    // Full text visible, wrapped: the region's space-stripped character
    // stream equals the buffer's (break-point spaces dropped, nothing
    // else — no foreign rows, no lost leading characters).
    final visible = region.map((l) => l.replaceAll(' ', '')).join();
    expect(visible, text.replaceAll(' ', ''), reason: 'region stream');

    // The first character opens the first region row — the line start
    // never slides out of view.
    expect(region.first.trimLeft().startsWith('please '), isTrue);

    // Wrapped, not one long row: ~200 chars at 80 cols must span 3 rows.
    expect(region.length, 3, reason: 'region rows: ${region.join(" | ")}');

    // Zero artifacts at row ends: the rules bracketing the region are
    // EXACTLY full-width rules (a stray digit or leftover fragment would
    // survive the trim), and every region row fits the viewport.
    expect(rows[rules[rules.length - 2]].trim(), rule);
    expect(rows[rules.last].trim(), rule);
    for (final row in region) {
      expect(row.runes.length, lessThanOrEqualTo(80));
      expect(row, isNot(contains('sleep')));
      expect(row, isNot(contains('mock')));
    }

    // The cursor renders at the TRUE end of the composed text: last region
    // row, one cell past the final glyph (grapheme-aware col math).
    final buffer = harness.terminal.buffer;
    final cursorRelRow = buffer.cursorY - (rules[rules.length - 2] + 1);
    expect(cursorRelRow, 2, reason: 'cursor on the last wrapped row');
    expect(buffer.cursorX, region.last.runes.length,
        reason: 'cursor one cell past the final glyph');
  });
}
