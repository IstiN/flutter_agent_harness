@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// gh-1724 follow-up: end-to-end CLI coverage for the gh-1680 message-cap
/// repair wiring (PR #1695). The loop/store/coalesce logic has unit suites
/// (test/agent/message_cap_*), but the CLI-side wiring — the learned-cap
/// store boot/persist in `agent_cli.dart`, the relief pass and the
/// pre-emptive gate in `agent_cli_compaction.dart`, and the
/// `MessageCapRepairEvent` surfaces in `approval_commands.dart` — is only
/// executed when a REAL [AgentCli] run rides a classified cap refusal.
/// These suites drive it in-process:
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
  // 1M window: the token trigger (window − reserve) can never fire — every
  // compaction below is driven by the gh-1680 message-count path alone.
  contextWindow: 1000000,
  maxTokens: 4096,
);

/// ~2.2k estimated tokens per `read` result: enough hideable mass that a
/// classic pass with a 200-token keep region actually shrinks the
/// transcript (a tiny transcript has nothing hideable and the relief
/// correctly reports a no-op).
final String _bigNote = List.filled(200, 'x' * 45).join('\n');

List<AssistantMessageEvent> _capRefusalTurn(String error) {
  final msg = testAssistant(stopReason: StopReason.error, errorMessage: error);
  return [
    StartEvent(partial: msg),
    ErrorEvent(reason: StopReason.error, error: msg),
  ];
}

List<AssistantMessageEvent> _readTurn(int n) => toolTurn([
  ToolCall(id: 't$n', name: 'read', arguments: {'path': 'note.txt'}),
]);

AgentCli _bootCli({
  required MemoryExecutionEnv env,
  required FakeCliIO io,
  required String homeDir,
  required StreamFunction stream,
}) => AgentCli(
  config: AgentCliConfig(
    model: _model,
    apiKey: 'test-key',
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
    env.writeFile('note.txt', _bigNote);
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
        // One prompt, 8 sequential tool delegations (17 transcript
        // messages — below the cap-24 pre-emptive trigger at 8 only in
        // COUNT; the relief pass hides the bulky old pairs), then the
        // provider's cap refusal, the relief's summarizer, and the
        // retried request.
        final turns = <List<AssistantMessageEvent>>[
          for (var i = 1; i <= 8; i++) _readTurn(i),
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

        // AC2: the learned cap persists for the NEXT process (the store
        // keys records by `provider<US>modelId`).
        final capsFile = File('${tempHome.path}/.fah/model_caps.json');
        expect(capsFile.existsSync(), isTrue);
        final decoded =
            jsonDecode(capsFile.readAsStringSync()) as Map<String, dynamic>;
        final record =
            decoded[ModelCapsStore.keyOf('test-provider', 'cap-model')]
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
            ModelCapsStore.keyOf('test-provider', 'cap-model'): {
              'maxMessages': 24,
            },
          }),
        );

        // REPL prompts, each answered by one tool delegation. After four
        // prompts the live transcript reaches 9 messages — past the
        // cap − margin trigger (24 − 16 = 8) — so the FIFTH prompt's
        // pre-flight gate must compact BEFORE the request rides out: the
        // additive gh-1680 trigger, token-healthy (the 1M window never
        // trips the token threshold).
        final turns = <List<AssistantMessageEvent>>[
          for (var i = 1; i <= 4; i++) _readTurn(i),
          textTurn('pre-emptive summary'),
          textTurn('prompt five answered after the gate'),
        ];
        final fake = FakeStreamFunction(turns);
        final cli = _bootCli(
          env: env,
          io: io,
          homeDir: tempHome.path,
          stream: fake.call,
        );

        final run = cli.run();
        for (var n = 1; n <= 5; n++) {
          io.sendLine('prompt $n');
          await settleUntil(() => fake.calls >= n);
        }
        await settleUntil(() => fake.calls >= 6);
        io.sendLine('/exit');
        await run;
        await io.close();

        // Calls: 4 tool prompts + the gate's summarizer + prompt five.
        expect(fake.calls, 6, reason: 'the pre-emptive pass adds one call');
        final beforeGate = fake.contexts[3].messages.length;
        final afterGate = fake.contexts[5].messages.length;
        expect(
          afterGate,
          lessThan(beforeGate),
          reason: 'the pre-emptive pass must shrink the transcript',
        );
        final output = io.out.toString();
        expect(output, contains('auto-compacted'));
        expect(output, contains('prompt five answered after the gate'));
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

/// Polls until [condition] holds (the REPL surfaces no per-turn marker
/// text; the stream call count is the observable turn boundary).
Future<void> settleUntil(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for the turn to settle');
}
