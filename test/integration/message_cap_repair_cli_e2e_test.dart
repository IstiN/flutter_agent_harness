@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// gh-1724 follow-up: end-to-end CLI coverage for the gh-1680 message-cap
/// repair wiring (PR #1695). The loop/store/coalesce logic has unit suites
/// (test/agent/message_cap_*), but the CLI-side wiring — the learned-cap
/// store boot/persist in `agent_cli.dart`, the relief pass in
/// `agent_cli_compaction.dart`, and the `MessageCapRepairEvent` surfaces in
/// `approval_commands.dart` — is only executed when a REAL [AgentCli] run
/// rides a classified cap refusal. These suites drive it in-process:
///
/// - learned-cap refusal (parseable limit): the heal learns the cap,
///   persists it to `<home>/.fah/model_caps.json`, compacts the transcript
///   through the host relief, retries once, and surfaces both notices.
/// - the persisted cap boot-loads into the NEXT process and the additive
///   message-count trigger compacts pre-flight (the `cap − margin` gate).
/// - cap-unknown refusal (no parseable limit): the relief finds nothing
///   hideable, the retry rides the coalesced payload alone, and the notice
///   says so.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

const _model = Model(
  id: 'cap-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 1000000,
  maxTokens: 4096,
);

List<AssistantMessageEvent> _capRefusalTurn(String error) {
  final msg = testAssistant(stopReason: StopReason.error, errorMessage: error);
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

AgentCli _bootCli({
  required MemoryExecutionEnv env,
  required FakeCliIO io,
  required String homeDir,
  required StreamFunction stream,
}) => AgentCli(
  config: AgentCliConfig(
    model: _model,
    apiKey: '[REDACTED:Sensitive Value]',
    env: env,
    homeDir: homeDir,
    sessionRoot: '/sessions',
    providerKind: 'openai-completions',
    compactionEngine: CompactionEngine.classic,
    compactionSettings: const CompactionSettings(
      enabled: true,
      reserveTokens: 100,
      keepRecentTokens: 200,
    ),
  ),
  io: io,
  streamFunction: stream,
);

void main() {
  late Directory tempHome;
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('fa_msgcap_cli_');
    env = MemoryExecutionEnv(cwd: '/work');
    env.writeFile('note.txt', 'small note\n');
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
    tempHome.deleteSync(recursive: true);
  });

  group('gh-1680 message-cap repair through the real CLI', () {
    test(
      'learned-cap refusal heals: persist, compact via relief, retry once',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        // One prompt, 8 sequential tool delegations (~18 transcript
        // messages — below the cap-24 pre-emptive trigger at 8 but plenty
        // of hideable turns for the relief pass), then the provider's cap
        // refusal, the relief's summarizer, and the retried request.
        final turns = <List<AssistantMessageEvent>>[
          for (var i = 1; i <= 8; i++)
            toolTurn([
              ToolCall(
                id: 't$i',
                name: 'read',
                arguments: {'path': 'note.txt'},
              ),
            ]),
          _capRefusalTurn('400 messages: array length 25 exceeds limit 24'),
          textTurn('summary of the earlier notes'),
          textTurn('recovered — task complete'),
        ];
        final fake = FakeStreamFunction(turns);
        final cli = _bootCli(
          env: env,
          io: io,
          homeDir: tempHome.path,
          stream: fake.call,
        );

        final exitCode = await cli.runHeadless('read the notes');
        await io.close();

        expect(exitCode, 0, reason: 'the heal must complete the turn');
        expect(
          fake.calls,
          11,
          reason: '8 tool turns + refusal + relief + retry',
        );

        // The repair is never silent: the loop-side event names the cap
        // and the refused count, and says the relief compacted.
        final output = io.out.toString();
        expect(output, contains('[message cap] provider refused the request'));
        expect(output, contains('(cap 24)'));
        expect(output, contains('context compacted, retrying once'));
        // The relief pass reports its own completion line.
        expect(
          output,
          contains('context compacted before the retry — continuing the turn'),
        );
        // The retried request rode the COMPACTED transcript.
        final refused = fake.contexts[8].messages.length;
        final retried = fake.contexts[9].messages.length;
        expect(
          retried,
          lessThan(refused),
          reason: 'the relief must shrink the payload before the retry',
        );
        expect(output, contains('recovered — task complete'));

        // AC2: the learned cap persists for the NEXT process.
        final capsFile = File('${tempHome.path}/.fah/model_caps.json');
        expect(capsFile.existsSync(), isTrue);
        final record =
            (jsonDecode(capsFile.readAsStringSync())
                    as Map<String, dynamic>)['test-provider']['cap-model']
                as Map<String, dynamic>;
        expect(record['maxMessages'], 24);
      },
    );

    test(
      'persisted cap boot-loads and the pre-emptive gate compacts before a request',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        // Seed the learned cap the way a previous process left it.
        final capsDir = Directory('${tempHome.path}/.fah')
          ..createSync(recursive: true);
        File('${capsDir.path}/model_caps.json').writeAsStringSync(
          jsonEncode({
            'test-provider': {
              'cap-model': {'maxMessages': 24},
            },
          }),
        );

        // REPL prompts, each answered by one tool delegation: after three
        // prompts the live transcript reaches cap − margin (24 − 16 = 8)
        // and the FOURTH prompt's pre-flight gate must compact BEFORE the
        // request rides out — the additive gh-1680 trigger, token-healthy
        // (the 1M window never trips the token threshold).
        final turns = <List<AssistantMessageEvent>>[
          for (var i = 1; i <= 3; i++)
            toolTurn([
              ToolCall(
                id: 't$i',
                name: 'read',
                arguments: {'path': 'note.txt'},
              ),
            ]),
          textTurn('pre-emptive summary'),
          textTurn('prompt four answered after the gate'),
        ];
        final fake = FakeStreamFunction(turns);
        final cli = _bootCli(
          env: env,
          io: io,
          homeDir: tempHome.path,
          stream: fake.call,
        );

        final run = cli.run();
        io.sendLine('prompt one');
        await io.settleAfter('prompt two');
        io.sendLine('prompt two');
        await io.settleAfter('prompt three');
        io.sendLine('prompt three');
        await io.settleAfter('prompt four');
        io.sendLine('prompt four');
        await io.settleAfter('prompt four answered after the gate');
        io.sendLine('/exit');
        await run;
        await io.close();

        // The gate fired BEFORE prompt four's request: the summarizer ran
        // (request 4) and the retried request (5) rode fewer messages than
        // prompt three's request (3).
        expect(fake.calls, 5, reason: '3 tool prompts + summarizer + prompt 4');
        expect(
          fake.contexts[3].messages,
          everyElement(isA<Message>()),
          reason: 'the summarizer request is a normal model call',
        );
        final beforeGate = fake.contexts[2].messages.length;
        final afterGate = fake.contexts[4].messages.length;
        expect(
          afterGate,
          lessThan(beforeGate),
          reason: 'the pre-emptive pass must shrink the transcript',
        );
        final output = io.out.toString();
        expect(output, contains('prompt four answered after the gate'));
      },
    );

    test(
      'cap-unknown refusal: relief no-op keeps the coalesce-only retry',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final fake = FakeStreamFunction([
          _capRefusalTurn('Error: 400 too many messages in one request'),
          textTurn('ok after coalesce'),
        ]);
        final cli = _bootCli(
          env: env,
          io: io,
          homeDir: tempHome.path,
          stream: fake.call,
        );

        final exitCode = await cli.runHeadless('say hi');
        await io.close();

        expect(exitCode, 0);
        expect(fake.calls, 2, reason: 'refusal + single coalesce-only retry');
        final output = io.out.toString();
        expect(output, contains('[message cap] provider refused the request'));
        expect(output, contains('coalescing the request, retrying once'));
        expect(output, isNot(contains('(cap ')));
        expect(output, contains('ok after coalesce'));
      },
    );
  });
}

extension _FakeCliIoSettle on FakeCliIO {
  /// Polls until [expected] appears in the captured output.
  Future<void> settleAfter(String expected) async {
    for (var i = 0; i < 300; i++) {
      if (out.toString().contains(expected)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for: $expected');
  }
}
