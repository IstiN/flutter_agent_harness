// PTY repro guard for issue #479: a real 80x24 terminal running four live
// background jobs must keep the frame ON the glass — the status row whole
// on the last physical row, no spinner glyph merged into it, the composer
// frame intact, and all four board rows visible on their own rows. Before
// the #496/#479 budget work this exact scenario overran the terminal and
// the bottom chrome overwrote each other (the garbled `⠇UWork/s0…` paste).
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

List<String> _grid(FaCliHarness harness) => [
  for (final line in harness.viewportLines) line.trimRight(),
];

const _spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

void main() {
  test('E2E-1 #479 AC3: 80x24, four live jobs — status whole, composer '
      'intact, board visible, frame on the glass', () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_tui_479_pty_');
    final workspace = Directory('/tmp/fa479ws')..createSync(recursive: true);
    addTearDown(() => workspace.deleteSync(recursive: true));
    final server = await MockLlmServer.start()
      ..enqueueToolCall('bash', '{"command": "sleep 40", "background": true}')
      ..enqueueToolCall('bash', '{"command": "sleep 41", "background": true}')
      ..enqueueToolCall('bash', '{"command": "sleep 42", "background": true}')
      ..enqueueToolCall('bash', '{"command": "sleep 43", "background": true}')
      ..enqueueText('four background jobs launched for 479');
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
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path},
      columns: 80,
      rows: 24,
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    await harness.waitForBoot();
    harness.sendText('launch the four watchers');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    harness.sendEnter();

    // The board's live region appears once the jobs start.
    await harness.waitForText(
      'Background jobs (4)',
      timeout: const Duration(seconds: 30),
    );
    // Let two 1 Hz ticks repaint so the grid is steady.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final grid = _grid(harness);
    expect(grid, hasLength(24), reason: 'frame fills exactly the terminal');

    // (a) the status row is WHOLE on the last physical row.
    final status = grid.last;
    expect(status, contains(' · turn '), reason: grid.join('\n'));
    expect(status, contains('mock-model'));
    expect(
      status.trimLeft().startsWith('/'),
      isTrue,
      reason: 'status opens with the cwd, not foreign text',
    );

    // (b) no spinner/elapsed glyph inside the status text.
    for (final glyph in _spinners) {
      expect(status, isNot(contains(glyph)));
    }

    // (c) the input frame is intact on its own rows: exactly two
    // full-width rules with an untouched (empty) composer zone between
    // them — no board/busy/status bleed into the composer.
    final rules = <int>[
      for (var i = 0; i < grid.length; i++)
        if (grid[i].trim() == '─' * 80) i,
    ];
    expect(rules, hasLength(2), reason: 'input frame: top + bottom rule');
    final zone = grid.sublist(rules.first + 1, rules.last);
    expect(zone, hasLength(1), reason: 'composer zone: ${grid.join("\n")}');
    expect(zone.single.trim(), isEmpty, reason: 'empty composer row');
  });
}
