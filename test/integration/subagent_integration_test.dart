@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

/// Issue #551: every leg here is keyless — model turns come from
/// `MockLlmServer` (scripted FIFO over the OpenAI wire) instead of the real
/// `~/.fah` config, so the file runs in the per-PR gate and can no longer rot
/// between releases (the #538 class).
void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('fa_subagent_test_');
    workspace = Directory.systemTemp.createTempSync('fa_subagent_ws_');
    // Keyless boot config (localhost:9999 is never contacted); mock-LLM tests
    // repoint baseUrl at their server before spawning.
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

  /// Repoints the boot config at [server] so parent AND subagent model turns
  /// are served by the same scripted FIFO.
  void useMockLlm(MockLlmServer server) {
    final config = File('${tempHome.path}/.fah/config.yaml');
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        'baseUrl: http://localhost:9999/v1',
        'baseUrl: ${server.baseUrl}',
      ),
    );
  }

  /// Spawns the CLI in the bare [workspace] — the repo root carries a
  /// knowledgebase/ whose background tag generator would steal FIFO slots
  /// from the scripted mock (the fa_cube/headless legs do the same).
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
    'task tool spawns a subagent that completes (full mock loop)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // Content-routed script (substring match on the LAST user message):
      // each request is answered by its own content, so background LLM
      // noise (memory tag generation, title/summary calls) can never steal
      // a slot — unmatched traffic degrades to a tolerated mock 500.
      final script = MockLlmScript.parse('''
scenarios:
  - match: "Use the task tool"
    responses:
      - toolCall:
          name: task
          arguments: >-
            {"context":"Prove the task loop","tasks":[{"name":"explorer1",
            "agent":"explore","task":"List the files in the current
            directory.","background":false}]}
      - text: "subagent finished: agent://explorer1 reported 3 files"
  - match: "List the files in the current directory"
    responses:
      - text: "subagent-done: 3 files listed"
  - match: "Existing tags:"
    responses:
      - text: ""
''');
      final server = await MockLlmServer.start(script: script);
      addTearDown(server.stop);
      useMockLlm(server);

      final harness = await spawnHarness();

      await harness.waitForBoot();

      harness.sendText(
        'Use the task tool with agent "explore" to list the files in the '
        'current directory. Reply with the result.',
      );
      harness.sendEnter();

      // Full loop semantics (issue #551 AC): user msg → task tool call →
      // subagent execution → agent:// result → parent reply. The task result row
      // proves the spawned subagent ran to completion; the subagent's own
      // model turn is proven on the wire (chatBodies); the parent's scripted
      // reply proves the result flowed back into a final turn. (The child's
      // text itself is captured into the agent:// artifact, not painted.)
      await harness.waitForText(
        'agent://',
        timeout: const Duration(seconds: 60),
      );
      // The contract is the PAINTED screen: the streamed sentence can hit
      // the raw stream (and paint prefix-first on a delta split) before the
      // frame carrying the whole row lands — an immediate screenText read
      // raced that window on loaded runners and saw a truncated row
      // (#920 PTY legs). gh-1049: anchor BOTH asserted rows on the screen
      // — the tool row and the finish line land a frame apart — and assert
      // on the captured screen instead of a fresh mid-render read.
      await harness.waitForScreen(
        '✔ task: Prove the task loop',
        timeout: const Duration(seconds: 30),
      );
      final screen = await harness.waitForScreen(
        'subagent finished: agent://explorer1',
        timeout: const Duration(seconds: 30),
      );
      expect(screen, contains('✔ task: Prove the task loop'));
      expect(screen, contains('subagent finished: agent://explorer1'));
      // >= 3 chat round-trips: parent tool-call turn, subagent turn, parent
      // reply turn (session title/summary calls may add more).
      expect(server.chatBodies.length, greaterThanOrEqualTo(3));
    },
  );

  test('/agents lists built-in agent types', () async {
    final harness = await spawnHarness();

    await harness.waitForBoot();
    await harness.runSlashCommand('/agents types');

    // The TUI paints the listing as one frame but repaints partial cells
    // (cursor jumps) — the RAW stream can carry "ag…nt types:" split by
    // escapes, so raw-contains is not assertable. Wait for the LAST line
    // of the listing: once it is on screen the whole frame is painted and
    // the viewport holds every row together.
    await harness.waitForText(
      'plan (built-in)',
      timeout: const Duration(seconds: 15),
    );
    final screen = harness.screenText;
    expect(screen, contains('agent types:'));
    expect(screen, contains('task'));
    expect(screen, contains('explore'));
    expect(screen, contains('review'));
  });

  test('/agents bare shows the live tree with main and children', () async {
    final harness = await spawnHarness();

    await harness.waitForBoot();

    await harness.runSlashCommand('/agents');

    // TUI picker shows the main orchestrator row (no subagents spawned yet).
    await harness.waitForText(
      'main (orchestrator)',
      timeout: const Duration(seconds: 15),
    );
    final screen = harness.screenText;
    expect(screen, contains('main (orchestrator)'));
  });

  test('memory_add and memory_search tools are available', () async {
    // Content-routed script: the parent prompt drives add → search → reply;
    // the memory package's background tag generator (its prompt carries
    // "Existing tags:") fires THREE times per round trip — once for the
    // add's enrichment, then once per search scope (project, then user:
    // the KB holds fewer records than the limit), so each gets a scripted
    // empty response and no call exhausts the FIFO into the 500-retry
    // storm (gh-1049 family).
    final script = MockLlmScript.parse('''
scenarios:
  - match: "Use the memory_add tool"
    responses:
      - toolCall:
          name: memory_add
          arguments: '{"text": "The project uses Dart 3.12"}'
      - toolCall:
          name: memory_search
          arguments: '{"query": "Dart"}'
      - text: "memory round-trip complete"
  - match: "Existing tags:"
    responses:
      - text: ""
      - text: ""
      - text: ""
''');
    final server = await MockLlmServer.start(script: script);
    addTearDown(server.stop);
    useMockLlm(server);

    final harness = await spawnHarness();

    await harness.waitForBoot();

    harness.sendText(
      'Use the memory_add tool to save this fact: "The project uses Dart '
      '3.12". Then use memory_search to find it.',
    );
    harness.sendEnter();

    // gh-1049 flake family, two stacked burial mechanisms: the TUI
    // diff-renders only changed cells (the raw stream never holds a
    // contiguous tool row), and the tag generator unconditionally print()s
    // its full prompt (~25-30 PTY lines per call, once per search scope)
    // between the add row and the final reply — the add row scrolls out of
    // the sampled viewport before the marker paints. waitForScreen samples
    // the visible viewport ONLY, so the surviving screen anchors are the
    // persistent terminal marker and the search row (it paints after the
    // last print burst). The add leg is proven at the wire level instead:
    // a parent turn must carry the memory_add tool call and the follow-up
    // turn its role:tool result (same chatBodies convention as the
    // task-tool leg; issue #551 AC: the full loop, not just boot).
    final screen = await harness.waitForScreen(
      'memory round-trip complete',
      timeout: const Duration(seconds: 30),
    );
    expect(screen, contains('✔ memory_search'));

    var sawAddCall = false;
    var addResultFedBack = false;
    for (final body in server.chatBodies) {
      final messages =
          (jsonDecode(body) as Map<String, dynamic>)['messages'] as List<dynamic>;
      for (var i = 0; i < messages.length; i++) {
        final calls =
            (messages[i] as Map<String, dynamic>)['tool_calls'] as List<dynamic>?;
        if (calls == null) continue;
        final isAdd = calls.any((c) =>
            ((c as Map<String, dynamic>)['function']
                as Map<String, dynamic>)['name'] ==
            'memory_add');
        if (!isAdd) continue;
        sawAddCall = true;
        if (i + 1 < messages.length &&
            (messages[i + 1] as Map<String, dynamic>)['role'] == 'tool') {
          addResultFedBack = true;
        }
      }
    }
    expect(sawAddCall, isTrue,
        reason: 'a parent turn carries the memory_add tool call');
    expect(addResultFedBack, isTrue,
        reason: 'the memory_add result flows back as a role:tool message');
    // >= 3 chat round-trips: add turn, search turn, reply turn.
    expect(server.chatBodies.length, greaterThanOrEqualTo(3));
  });
}
