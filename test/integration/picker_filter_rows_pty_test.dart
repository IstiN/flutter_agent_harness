// Issue #595: the CLI TUI's filtered pickers rendered illegibly. The menu
// row renderer measured fuzzy-highlighted labels WITHOUT stripping their
// embedded SGR runs, so every matched row "measured" ~3× its visible width
// and `_menuItemRow` elided it to a few visible chars — typing `/se` to
// find the `/sessions` command showed a cramped column of 15-char stubs
// (`/sessions list…`) instead of readable rows.
//
// Contract proven here over the REAL headless TUI with a scripted LLM
// (MockLlmServer, no network):
// - the `/sessions` picker type-to-filter shows the matching rows (indexed
//   into the full list) with the selection cursor, and `(no matches)` on
//   an empty result (the AGENTS.md picker contract);
// - the filtered command palette shows FULL untruncated row text and the
//   selection cursor.
//
// Waits are anchored polling only (#533/#550/#557 deflake precedent) —
// no fixed sleeps beyond the 200ms output-settle window.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'filtered pickers show readable rows, cursor, and (no matches) (#595)',
    () async {
      final tempHome = Directory.systemTemp.createTempSync('fa_tui_595_');
      final workspace = Directory.systemTemp.createTempSync('fa595ws_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final server = await MockLlmServer.start();
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

      // Seed named sessions so the picker has real rows. Newest sorts
      // first within the folder, so the picker numbers them:
      // 1) gamma-four, 2) beta-three, 3) alpha-two, 4) alpha-one.
      for (final name in ['alpha-one', 'alpha-two', 'beta-three', 'gamma-four']) {
        await harness.runSlashCommand('/session-new $name');
        await harness.waitForText(
          "created session '$name'",
          timeout: const Duration(seconds: 20),
        );
      }
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );

      // Open the /sessions picker: full list, cursor on the first row.
      await harness.runSlashCommand('/sessions');
      await harness.waitForScreen(
        '[Sessions]',
        timeout: const Duration(seconds: 10),
      );
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );
      var screen = harness.viewportLines.join('\n');
      // On open the cursor sits on the first item — the flat/tree toggle;
      // numbered rows follow in recency order (newest first).
      expect(screen, contains('▸ ⟳ flat list'));
      expect(screen, contains('1) gamma-four'));
      expect(screen, contains('4) alpha-one'));

      // Type-to-filter `alp`: exactly the two alpha rows stay, selection
      // cursor on the first match, non-matching rows leave the menu.
      harness.sendText('alp');
      await harness.waitForScreen(
        '[Sessions: alp]',
        timeout: const Duration(seconds: 10),
      );
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );
      screen = harness.viewportLines.join('\n');
      expect(screen, contains('▸ 3) alpha-two'));
      expect(screen, contains('4) alpha-one'));
      // The `N)` index prefixes keep these assertions unambiguous against
      // the seeded `/session-new` echoes in the transcript history.
      expect(screen, isNot(contains('1) gamma-four')));
      expect(screen, isNot(contains('2) beta-three')));

      // An empty result keeps the title + the dim (no matches) hint.
      harness.sendText('zzzz');
      await harness.waitForScreen(
        '(no matches)',
        timeout: const Duration(seconds: 10),
      );
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );
      screen = harness.viewportLines.join('\n');
      expect(screen, contains('[Sessions: alpzzzz]'));
      expect(screen, contains('(no matches)'));

      // Back to the full list, then close the picker.
      for (var i = 0; i < 8; i++) {
        harness.sendBackspace();
      }
      await harness.waitForScreen(
        '[Sessions]',
        timeout: const Duration(seconds: 10),
      );
      harness.sendEscape();
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );

      // THE #595 REGRESSION: typing `/se` filters the command palette to
      // the sessions-family commands — every row must show its FULL label
      // + description (pre-fix: `/sessions list…`, a 15-char stub) with
      // the selection cursor on the first row.
      harness.sendText('/se');
      await harness.waitForScreen(
        'list all sessions across workspaces',
        timeout: const Duration(seconds: 10),
      );
      await harness.waitForOutput(
        settleMs: 200,
        timeout: const Duration(seconds: 5),
      );
      screen = harness.viewportLines.join('\n');
      expect(screen, contains('[Commands]'));
      expect(screen, contains('▸ /session '));
      expect(screen, contains('list all sessions across workspaces'));
      expect(screen, contains('create a new named session'));
      // The truncated-stub shape is gone: no menu row may end in an
      // ellipsis mid-description.
      expect(screen, isNot(contains('list…')));
    },
  );
}
