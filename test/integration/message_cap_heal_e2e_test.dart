@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// gh-1680 message-cap handling through the REAL headless binary
/// (`runFaHeadless`, AOT seam via FA_BIN) — the e2e complement to the
/// in-process wiring tests (test/cli/agent_cli_message_cap_test.dart)
/// and the loop fakes (test/agent/message_cap_loop_test.dart):
///
/// - Reactive heal: a provider 400 shaped `array length N exceeds limit
///   M` classifies as a cap refusal, the learned cap persists to
///   `<home>/.fah/model_caps.json` (AC2), and the single retry completes
///   the turn (relief + armed-payload coalesce ride the CLI glue in
///   lib/src/cli/agent_cli_compaction.dart).
/// - Boot-loaded pre-emptive gate (AC2+AC4): a store seeded with a small
///   learned cap makes a multi-tool-round turn compact BEFORE a request
///   once the live count reaches `cap − margin`, and the turn still
///   completes.
///
/// Mock-endpoint only (package:fa_llm_mock) — no live provider, no PTY.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';

void main() {
  group('gh-1680 message-cap heal (real headless CLI)', () {
    late Directory tempHome;
    late Directory workspace;
    late MockLlmServer server;

    setUp(() async {
      tempHome = Directory.systemTemp.createTempSync('fa_cap_home_');
      workspace = Directory.systemTemp.createTempSync('fa_cap_ws_');
      // mode/approval ride the config so the bash tool runs unattended;
      // provider/baseUrl/model come from the runFaHeadless flags.
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('mode: code\napprovalMode: yolo\n');
      addTearDown(() {
        tempHome.deleteSync(recursive: true);
        workspace.deleteSync(recursive: true);
      });
    });

    String capsPath() => '${tempHome.path}/.fah/model_caps.json';

    /// Seeds the learned-cap store the way the CLI persists it, so the
    /// boot under test LOADS a real cap instead of the test poking
    /// process state.
    void seedCap(String provider, String model, int cap) {
      ModelCapsStore(
        initial: {
          ModelCapsStore.keyOf(provider, model): ModelCapRecord(
            maxMessages: cap,
          ),
        },
      ).persist(capsPath());
    }

    Future<FaResult> runFa(String prompt) {
      return runFaHeadless(
        workspace: workspace,
        baseUrl: server.baseUrl,
        prompt: prompt,
        env: {'HOME': tempHome.path},
      );
    }

    test(
      'a cap refusal heals: learn, persist, coalesce, retry (AC1/AC2)',
      () async {
        server = await MockLlmServer.start(
          script: MockLlmScript.parse('''
responses:
  - text: "summary of earlier turns"
scenarios:
  - match: "cap please"
    responses:
      - error: {status: 400, message: "400 messages: array length 2049 exceeds limit 2048"}
      - text: "healed reply"
'''),
        );
        addTearDown(server.stop);

        final result = await runFa('cap please');

        // The heal rode the CLI relief/coalesce glue and the turn completed
        // on the retried request.
        expect(result.exitCode, 0, reason: result.output);
        expect(result.stdout, contains('healed reply'), reason: result.output);

        // The parsed cap persisted for the next boot (AC2).
        final capsFile = File(capsPath());
        expect(capsFile.existsSync(), isTrue, reason: result.output);
        final persisted =
            jsonDecode(capsFile.readAsStringSync()) as Map<String, dynamic>;
        expect(
          persisted.values
              .whereType<Map>()
              .map((r) => r['maxMessages'])
              .whereType<int>(),
          contains(2048),
        );
      },
    );

    test('a boot-loaded cap compacts pre-emptively at cap − margin '
        '(AC2+AC4)', () async {
      server = await MockLlmServer.start(
        script: MockLlmScript.parse('''
responses:
  - text: "summary of earlier turns"
scenarios:
  - match: "grow the transcript"
    sticky: true
    responses:
      - toolCall:
          name: bash
          arguments: '{"command": "echo cap-a"}'
      - toolCall:
          name: bash
          arguments: '{"command": "echo cap-b"}'
      - toolCall:
          name: bash
          arguments: '{"command": "echo cap-c"}'
      - toolCall:
          name: bash
          arguments: '{"command": "echo cap-d"}'
      - text: "cap-aware done"
'''),
      );
      addTearDown(server.stop);

      // cap 24 with the default margin 16 arms the trigger at 8 live
      // messages; four tool rounds reach 9 before the final request.
      seedCap('openai-completions', 'mock-model', 24);

      final result = await runFa('grow the transcript');

      expect(result.exitCode, 0, reason: result.output);
      expect(result.stdout, contains('cap-aware done'), reason: result.output);
    });
  });
}
