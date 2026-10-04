@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// Issue #45: the config-driven mock LLM provider end-to-end.
///
/// Starts `MockLlmServer` from YAML/JSON script files and drives the REAL
/// headless `fah` CLI against it — proving the full tool-execution loop
/// (user message → scripted tool call → sandboxed execution → tool result
/// → scripted reply) and the error-simulation path over the actual
/// OpenAI-compatible wire protocol.
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';

void main() {
  group('fa_llm_mock config-driven integration', () {
    late Directory tempHome;
    late Directory workspace;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('fa_mock_test_');
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: openai-completions
model: mock-model
mode: code
approvalMode: yolo
allowedTools: []
''');
      workspace = Directory.systemTemp.createTempSync('fa_mock_ws_');
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });

    Future<FaResult> runFa(MockLlmServer server, String prompt) {
      return runFaHeadless(
        workspace: workspace,
        baseUrl: server.baseUrl,
        prompt: prompt,
        env: {'HOME': tempHome.path},
      );
    }

    test('yaml script drives a full tool loop in the real CLI', () async {
      final scriptFile = File('${workspace.path}/mock_script.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
model: mock-model
scenarios:
  - match: "make a marker"
    responses:
      - toolCall:
          name: bash
          arguments: '{"command": "echo mock-loop-ok"}'
      - toolResultEcho: true
''');
      final server = await MockLlmServer.start(
        script: MockLlmScript.parseFile(scriptFile.path),
      );
      addTearDown(server.stop);

      final result = await runFa(server, 'please make a marker');

      // Two model calls: the scripted tool call, then the echo of the
      // tool RESULT — which only appears if the sandbox truly ran echo.
      expect(server.chatCalls, 2);
      expect(server.chatBodies.first, contains('"tools"'));
      expect(result.stdout, contains('mock-loop-ok'));
      expect(result.exitCode, 0);
    });

    test('json script error simulation fails the run cleanly', () async {
      final scriptFile = File('${workspace.path}/mock_script.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{
  "scenarios": [
    {"match": "simulate an outage", "responses": [{"error": {"status": 503, "message": "mock outage"}}]}
  ]
}
''');
      final server = await MockLlmServer.start(
        script: MockLlmScript.parseFile(scriptFile.path),
      );
      addTearDown(server.stop);

      final result = await runFa(server, 'simulate an outage');

      // The roles retry policy retries a 503 in place (default
      // `retriesPerEntry: 2`) — one script hit plus two retries = 3
      // calls before the run gives up.
      expect(server.chatCalls, 3);
      expect(result.output, contains('mock outage'));
      expect(result.exitCode, isNot(0));
    });

    test(
      'scripted scenario serves then exhausts with a clean failure',
      () async {
        // gh-1199 AC3/E4: the conversation is scenario-routed on a unique
        // marker so INCIDENTAL mock traffic (background tag generation,
        // title/summary calls) can never pop the scripted response the way
        // it popped the one-entry top-level fallback queue in run
        // 37131131303 (unmatched traffic degrades to a tolerated mock 500;
        // the known auto-tag noise is pinned to a sticky wildcard, gh-1171).
        // The top-level `responses:` fallback queue itself is exercised
        // serve-then-exhaust at the unit level in
        // packages/fa_llm_mock/test/mock_llm_server_test.dart — no CLI boot
        // noise can reach it there.
        final scriptFile = File('${workspace.path}/mock_script.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync('''
scenarios:
  - match: "fa-fallback-probe"
    responses:
      - text: fallback reply
  - match: "Existing tags:"
    sticky: true
    responses:
      - text: ""
''');
        final server = await MockLlmServer.start(
          script: MockLlmScript.parseFile(scriptFile.path),
        );
        addTearDown(server.stop);

        final first = await runFa(server, 'fa-fallback-probe');
        expect(first.stdout, contains('fallback reply'));
        expect(first.exitCode, 0);

        // The marker matches again but the queue is dry: a matched-but-dry
        // scenario answers the HTTP 500 `script exhausted` — surfaced as a
        // clean run failure, never a silent empty turn.
        final second = await runFa(server, 'fa-fallback-probe again');
        expect(second.output, contains('script exhausted'));
        expect(second.exitCode, isNot(0));
      },
    );
  });
}
