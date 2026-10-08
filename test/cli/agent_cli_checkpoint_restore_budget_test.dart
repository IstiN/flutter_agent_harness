// gh-1425 AC4 — budget-guarded restore at checkpoint auto-close: the user
// turn that ends a checkpoint detour leaves the FULL detour history live
// (no rewind prunes it). When that restored context sits over the
// compaction trigger (window − reserve — the same budget the boot cap
// gates on), the remainder is compacted BEFORE the next request, mid-run,
// and the loop adopts the capped transcript at the next turn boundary.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
const _reserve = 8192;
// CompactionSettings.forWindow(32768): reserve = window ~/ 4.
final _threshold = _window - _reserve;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

void main() {
  late FakeCliIO io;
  late MemoryExecutionEnv env;

  setUp(() {
    io = FakeCliIO();
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (same pattern as
    // agent_cli_test) so the scripted turns feed only the scenario.
    env.writeFile('/work/.fah/memory/.last_maintenance', '');
    // The mid-run detonation payload: a real `read` tool result (~6k
    // estimated tokens) that pushes the restored detour context over the
    // compaction trigger — but UNDER the window itself, so the loop's
    // gross over-window guard stays out and the AC4 guard owns the cap.
    env.writeFile('big.txt', List.filled(1000, 'x' * 24).join('\n'));
  });
  tearDown(() => io.close());

  /// Seeds the resumed session with a base transcript just UNDER the
  /// compaction trigger (11 × ~1k-token messages + the ~10k request
  /// overhead ≈ 21k of a 24,576 trigger): no boot cap, no pre-flight
  /// compaction — the ONLY thing that pushes the context over the trigger
  /// is the mid-run restore in run 3. The post-read transcript (~17k)
  /// also stays under the summarizer's single-chunk payload budget
  /// (window − reserve = 24,576), so the forced pass makes exactly ONE
  /// summarizer call.
  Future<void> seedBaseTranscript() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('restore-budget-target');
    for (var i = 0; i < 11; i++) {
      await seed.appendMessage(UserMessage.text('seed$i ${'a' * 4000}'));
    }
  }

  AgentCli cli(FakeStreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'restore-budget-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      // Keep region small enough that ONE pass clears the trigger: the
      // default keep (window ~/ 2 = 16384) plus the ~10k request overhead
      // would sit over the 24,576 trigger and re-fire the pass loop.
      compactionSettings: const CompactionSettings(
        enabled: true,
        reserveTokens: 8192,
        keepRecentTokens: 4096,
      ),
    ),
    io: io,
    streamFunction: stream.call,
  );

  int requestTokensOf(Context context) =>
      estimateContextTokens(context.messages).tokens +
      estimateRequestOverheadTokens(context.systemPrompt, context.tools ?? const []);

  test(
    'AC4: a user turn that auto-closes a checkpoint over the trigger gets '
    'the remainder compacted before the next request (window − reserve)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      await seedBaseTranscript();
      final stream = FakeStreamFunction([
        // Run 1 ("start the detour"): the model marks a checkpoint.
        toolTurn([
          const ToolCall(
            id: 'c1',
            name: 'checkpoint',
            arguments: {'goal': 'detour'},
          ),
        ]),
        textTurn('detour started'),
        // Run 2 ("any luck?"): a REAL user turn lands inside the detour
        // scope — the checkpoint goes stale (userTurn) from here on.
        textTurn('no findings yet'),
        // Run 3 ("wrap it up"): first balloon the context past the
        // trigger with a real tool result…
        toolTurn([
          const ToolCall(id: 't1', name: 'read', arguments: {'path': 'big.txt'}),
        ]),
        // …then close the stale checkpoint: the auto-close fires the AC4
        // restore-budget guard (over the trigger → forced pass).
        toolTurn([
          const ToolCall(
            id: 'c2',
            name: 'checkpoint',
            arguments: {'goal': 'close it out'},
          ),
        ]),
        // The guard's forced compaction summarizer.
        textTurn('restore budget compaction summary'),
        // The run continues ON THE CAPPED CONTEXT.
        textTurn('final answer after restore budget cap'),
      ]);
      final agent = cli(stream);

      final run = agent.run();
      io.sendLine('start the detour');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'run 1 created the checkpoint',
      );
      io.sendLine('any luck?');
      await waitForIt(
        () => stream.calls >= 3 && !agent.isBusy,
        reason: 'run 2 landed the real user turn inside the detour scope',
      );
      io.sendLine('wrap it up');
      await waitForIt(
        () =>
            !agent.isBusy &&
            io.out.toString().contains('final answer after restore budget cap'),
        reason: 'run 3: read → stale-checkpoint auto-close → guard cap → '
            'final answer',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // …the guard's cap is visible in the transcript…
      expect(output, contains('[checkpoint]'));
      // …and the run completed on it.
      expect(output, contains('final answer after restore budget cap'));
      expect(output, isNot(contains('error:')));

      // Fixture sanity: no compaction fired before run 3 — the boot and
      // the first two pre-flights were UNDER the trigger.
      expect(requestTokensOf(stream.contexts.first), lessThan(_threshold));

      // The detonation was real: at the auto-close the restored context
      // (full detour history + the big tool result) sat OVER the trigger.
      expect(
        requestTokensOf(stream.contexts[4]),
        greaterThan(_threshold),
        reason: 'fixture check: the auto-close must fire over the trigger',
      );

      // AC4: the next request after the auto-close rides the CAPPED
      // context — never above window − reserve.
      expect(
        requestTokensOf(stream.contexts.last),
        lessThanOrEqualTo(_threshold),
      );

      // The audit record names the user-turn close.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list();
      expect(sessions, hasLength(1));
      final session = await repo.open(sessions.first);
      final audit = (await session.getEntries())
          .whereType<CustomMessageRecord>()
          .where((r) => r.customType == checkpointAutoClosedCustomType)
          .toList();
      expect(audit, hasLength(1));
      expect(
        (audit.single.details! as Map<String, Object?>)['reason'],
        'userTurn',
      );
    },
  );

  test(
    'AC4 no-op: an auto-close UNDER the trigger compacts nothing — the '
    'existing behavior is preserved for healthy sessions',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      env.writeFile('big.txt', 'tiny\n');
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 'c1',
            name: 'checkpoint',
            arguments: {'goal': 'detour'},
          ),
        ]),
        textTurn('detour started'),
        textTurn('no findings yet'),
        toolTurn([
          const ToolCall(
            id: 'c2',
            name: 'checkpoint',
            arguments: {'goal': 'close it out'},
          ),
        ]),
        textTurn('final answer, no cap needed'),
      ]);
      final agent = cli(stream);

      final run = agent.run();
      io.sendLine('start the detour');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'run 1 created the checkpoint',
      );
      io.sendLine('any luck?');
      await waitForIt(
        () => stream.calls >= 3 && !agent.isBusy,
        reason: 'run 2 settled',
      );
      io.sendLine('wrap it up');
      await waitForIt(
        () => stream.calls >= 5 && !agent.isBusy,
        reason: 'run 3: the stale checkpoint auto-closed under the trigger',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // The guard stayed out of the way: no cap receipt, no summarizer
      // call between the auto-close and the final answer.
      expect(output, isNot(contains('[checkpoint]')));
      expect(stream.calls, 5);
      expect(output, contains('final answer, no cap needed'));
    },
  );
}
