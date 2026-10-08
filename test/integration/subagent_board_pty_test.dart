@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 5))
library;

// gh-1415 E2E-1 / AC6: a scripted BACKGROUND task spawn in the PTY harness
// shows the subagent status row language end to end — the row APPEARS on
// spawn (one dense line: glyph, state verb, human name, age, cost), TICKS
// in place (the age recomputes from the spawn timestamp on the 1 Hz
// repaint), and COLLAPSES to the settled one-liner on completion. The
// child runs a real `bash sleep 6` (general-purpose `task` agent —
// `explore` is read-only and has no bash tool) so the running row lives
// long enough to observe deterministically.
//
// Structure mirrors subagent_integration_test.dart (#551): bare-workspace
// boot, content-routed MockLlmScript, keyless localhost config repointed
// at the server before spawn.
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('fa_subagent_board_');
    workspace = Directory.systemTemp.createTempSync('fa_subagent_board_ws_');
    // Keyless boot config (localhost:9999 is never contacted); the mock
    // server repoints baseUrl before spawn.
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
tui:
  classic: true  # pins the classic chrome; band redesign #805-#807
''');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  /// Repoints the boot config at [server] so parent AND subagent model
  /// turns are served by the same scripted content router.
  void useMockLlm(MockLlmServer server) {
    final config = File('${tempHome.path}/.fah/config.yaml');
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        'baseUrl: http://localhost:9999/v1',
        'baseUrl: ${server.baseUrl}',
      ),
    );
  }

  /// Spawns the CLI in the bare [workspace] — no knowledgebase, so the
  /// background tag generator cannot steal FIFO slots from the script.
  Future<FaCliHarness> spawnHarness() async {
    final harness = await FaCliHarness.spawn(
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path},
    );
    harness.startListening();
    addTearDown(() async => harness.close());
    return harness;
  }

  test(
    'background task spawn: the status row appears, ticks, collapses (AC6)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Content-routed script (substring match on the LAST user message).
      // The child's second request still matches its own scenario (its
      // tool result rides role:tool), so the two-response child script
      // pops in order: bash sleep → final text. The child must be the
      // general-purpose `task` agent — `explore` is read-only (no bash
      // tool), so its toolCall would fail instantly and the running row
      // would live <1s, unobservable.
      final script = MockLlmScript.parse('''
scenarios:
  - match: "Use the task tool"
    responses:
      - toolCall:
          name: task
          arguments: >-
            {"context":"Prove the board","tasks":[{"name":"boardwatch",
            "agent":"task","task":"Count the files in the current
            directory.","background":true}]}
      - text: "spawned boardwatch in the background"
  - match: "Count the files in the current directory"
    responses:
      - toolCall:
          name: bash
          arguments: '{"command": "sleep 4"}'
      - text: "boardwatch-done: counted"
  - match: "Existing tags:"
    sticky: true
    responses:
      - text: ""
''');
      final server = await MockLlmServer.start(script: script);
      addTearDown(server.stop);
      useMockLlm(server);

      final harness = await spawnHarness();
      await harness.waitForBoot();

      harness.sendText(
        'Use the task tool in the background with agent "explore" and '
        'name "boardwatch". Reply when spawned.',
      );
      harness.sendEnter();

      // APPEARING: the live row renders as ONE dense line — the state verb
      // and the human NAME (never a mailbox uuid) on the same row.
      final appearing = await harness.waitForScreen(
        'run  boardwatch',
        timeout: const Duration(seconds: 90),
      );
      expect(appearing, contains('run  boardwatch'));

      // TICKING: the 1 Hz ticker re-renders the age from the spawn
      // timestamp in place — dart_tui diff-renders, so the raw stream
      // only ever carries the CHANGED cells (the age digit), never the
      // full row again; anchor the tick on the rendered screen instead.
      await harness.waitForScreen(
        RegExp('run  boardwatch\\s+[2-9]s'),
        timeout: const Duration(seconds: 30),
      );

      // COLLAPSING: the settle flash then the dim one-line summary — the
      // done verb and the name still share ONE row (never a block). The
      // state field is 4 cells: `done` fills it exactly, so the name
      // follows after ONE space (`run` pads to `run ` and shows two).
      final settled = await harness.waitForScreen(
        RegExp('done\\s+boardwatch'),
        timeout: const Duration(seconds: 90),
      );
      expect(settled, contains('done boardwatch'));
    },
  );
}
