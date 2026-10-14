// gh-1604 items 2+3 — the bench compaction trigger wired through the real
// CLI gate (AC2/AC3 mechanism layer).
//
// `FAH_COMPACT_TRIGGER_TOKENS` fires the auto-compaction at an absolute
// context size where the window-minus-reserve default would NOT fire, the
// compaction event lands in the session JSONL, and the post-compaction
// projection still carries the obligations ledger block and the latest
// tool result — while the summarization request the pipeline issued
// contained the task text (the mechanism that carries it into the rolling
// summary on real runs).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
// CompactionSettings.forWindow(32768): reserve = min(16384, window ~/ 4)
// = 8192 → the DEFAULT trigger is 24576 estimated tokens.
final _defaultTrigger = _window - 8192;
// The bench trigger fires at 6000 — far below the default.
const _benchTrigger = '6000';

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

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// Seeds a session whose estimate sits BETWEEN the bench trigger and
  /// the default one: ~14k estimated tokens. The task text rides the
  /// first user message; the obligations ledger carries one open entry; a
  /// valid tool pair (assistant call + result) provides the latest tool
  /// result at seed time.
  Future<MemoryExecutionEnv> seedBetweenTriggers(
    String name, {
    MemoryExecutionEnv? into,
  }) async {
    final env = into ?? MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (suite pattern).
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    // The task text (the first real user message).
    await seed.appendMessage(
      UserMessage.text(
        'TASK build the mips interpreter; keep the ledger obligations; '
        '${'task ' * 120}',
      ),
    );
    // The obligations ledger: one open owner rule (the AC3 payload).
    const ledgerText = 'always run the full test suite before pushing';
    await seed.appendCustomEntry(
      customType: obligationsLedgerRecordType,
      data: [
        {
          'id': 'obl-test-1',
          'kind': 'owner-rule',
          'text': ledgerText,
          'sourceRecordId': 'rec-1',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'status': 'open',
        },
      ],
    );
    // A valid tool pair: the call, then the result.
    await seed.appendMessage(
      AssistantMessage(
        content: [
          const ToolCall(id: 'call-seed-1', name: 'read', arguments: {}),
        ],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.utc(2026),
      ),
    );
    await seed.appendMessage(
      ToolResultMessage(
        toolCallId: 'call-seed-1',
        toolName: 'read',
        content: [const TextContent(text: 'latest seed tool result')],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    // Filler: 12 × ~1000 chars ≈ 3000 estimated tokens … plus the records
    // above lands the transcript between 6000 (bench) and 24576 (default).
    for (var i = 0; i < 12; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
    return env;
  }

  AgentCli cli(MemoryExecutionEnv env, FakeStreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'bench-trigger-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
    ),
    io: io,
    environment: {'FAH_COMPACT_TRIGGER_TOKENS': _benchTrigger},
    streamFunction: stream.call,
  );

  int requestTokensOf(Context context) =>
      estimateContextTokens(context.messages).tokens +
      estimateRequestOverheadTokens(
        context.systemPrompt,
        context.tools ?? const [],
      );

  test(
    'the bench trigger fires where the default would not; the compaction '
    'event lands in the JSONL; obligations + latest tool result survive',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedBetweenTriggers('bench-trigger-target');
      final stream = FakeStreamFunction([
        // Turn 1's answer …
        textTurn('first answer'),
        // … then the compaction summarizer (fires post-turn) …
        textTurn('rolling summary of the bench task'),
        // … then turn 2's answer rides the compacted context.
        textTurn('second answer'),
      ]);
      final agent = cli(env, stream);

      final run = agent.run();
      io.sendLine('go');
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the first turn answers',
      );

      // Sanity: the pre-compaction request sat between the two triggers —
      // the bench trigger fired where the DEFAULT never would have.
      final firstRequestTokens = requestTokensOf(stream.contexts.first);
      expect(firstRequestTokens, greaterThan(int.parse(_benchTrigger)));
      expect(firstRequestTokens, lessThanOrEqualTo(_defaultTrigger));

      io.sendLine('go again');
      await waitForIt(
        () => stream.calls >= 3 && !agent.isBusy,
        reason: 'the compaction pass runs and the second turn answers',
      );
      io.sendLine('/exit');
      await run;

      // The auto-compaction ran and was announced.
      expect(io.out.toString(), contains('auto-compacted'));

      // AC3: the compaction event is VISIBLE in the session JSONL.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      expect(sessions, hasLength(1));
      final session = await repo.open(sessions.single);
      final entries = await session.getEntries();
      expect(
        entries.whereType<CompactionRecord>(),
        isNotEmpty,
        reason: 'a compaction record must land in the session file',
      );

      // The summarizer request carried the task text — the mechanism that
      // folds it into the rolling summary on real runs.
      final summaryRequestsContainTask = stream.contexts.any(
        (context) => context.messages.any(
          (message) =>
              message is UserMessage &&
              messageText(message).contains('build the mips interpreter'),
        ),
      );
      expect(summaryRequestsContainTask, isTrue);

      // AC3: the post-compaction projection keeps the obligations block
      // and the latest tool result.
      final projected = await session.buildContextMessages();
      final projectedText = [
        for (final m in projected)
          switch (m) {
            UserMessage() => messageText(m),
            ToolResultMessage() =>
              m.content.whereType<TextContent>().map((b) => b.text).join(),
            _ => '',
          },
      ].join('\n');
      expect(projectedText, contains('obligations ledger'));
      expect(projectedText, contains('always run the full test suite'));
      expect(projectedText, contains('latest seed tool result'));

      // The compacted request is bounded by the bench trigger's shape:
      // the second turn's request stays well under the default trigger.
      expect(requestTokensOf(stream.contexts.last), lessThan(_defaultTrigger));
    },
  );

  test(
    'without the env the same session does NOT compact (byte-identical '
    'default behavior)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedBetweenTriggers('bench-trigger-target');
      final stream = FakeStreamFunction([
        textTurn('first answer'),
        textTurn('second answer'),
      ]);
      final agent = AgentCli(
        config: AgentCliConfig(
          model: _model,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'bench-trigger-target',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        // NO environment: the legacy default applies.
        streamFunction: stream.call,
      );

      final run = agent.run();
      io.sendLine('go');
      await waitForIt(
        () => stream.calls >= 1 && !agent.isBusy,
        reason: 'the first turn answers',
      );
      io.sendLine('go again');
      await waitForIt(
        () => stream.calls >= 2 && !agent.isBusy,
        reason: 'the second turn answers without a compaction',
      );
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), isNot(contains('auto-compacted')));
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.open((await repo.list(cwd: '/work')).single);
      expect(
        (await session.getEntries()).whereType<CompactionRecord>(),
        isEmpty,
      );
    },
  );
}
