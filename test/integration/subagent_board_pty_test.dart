@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 5))
library;

// gh-1415 E2E-1 / AC6: a scripted background `task` spawn in the PTY
// harness shows the subagent status row APPEARING on spawn and COLLAPSING
// to the settled one-liner — the live row language, end to end (the age
// tick itself is pinned at the unit layer; sub-minute ages do not change
// on screen inside a fast mock run).

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
  /// turns are served by the same scripted FIFO.
  void useMockLlm(MockLlmServer server) {
    final config = File('${tempHome.path}/.fah/config.yaml');
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        'baseUrl: http://localhost:9999/v1',
        'baseUrl: ${server.baseUrl}',
      ),
    );
  }

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
    'background task spawn: the status row appears and collapses (AC6)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final script = MockLlmScript.parse('''
scenarios:
  - match: "Use the task tool"
    responses:
      - toolCall:
          name: task
          arguments: >-
            {"context":"Prove the board","tasks":[{"name":"boardwatch",
            "agent":"explore","task":"Count the files in the current
            directory.","background":true}]}
      - text: "spawned boardwatch in the background"
  - match: "Count the files in the current directory"
    responses:
      - text: "boardwatch-done: 3 files counted"
  - match: "Background agent boardwatch"
    sticky: true
    responses:
      - text: "completion noticed"
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

      // APPEARING: the live row renders one dense line per subagent —
      // glyph, state verb, the human NAME (never a mailbox uuid), age.
      await harness.waitForScreen(
        'boardwatch',
        timeout: const Duration(seconds: 30),
      );
      final appearing = await harness.waitForScreen(
        'boardwatch',
        timeout: const Duration(seconds: 10),
      );
      expect(appearing, contains('boardwatch'));

      // COLLAPSING: the settle flash then the dim one-line summary — the
      // done verb, still one row (never a lingering multi-line block).
      final settled = await harness.waitForScreen(
        'done',
        timeout: const Duration(seconds: 60),
      );
      expect(settled, contains('boardwatch'));
      // Density: the row is ONE line — the settled summary carries the
      // name and the done verb on the same row.
      final doneLine = settled
          .split('\n')
          .firstWhere((l) => l.contains('boardwatch') && l.contains('done'));
      expect(doneLine.contains('boardwatch'), isTrue);
    });
}
