// gh-1604 items 2+3 — the bench compaction trigger wired through the real
// CLI gates (AC2/AC3 mechanism layer).
//
// `FAH_COMPACT_TRIGGER_TOKENS` fires the auto-compaction at an absolute
// context size (here 6000) where the window-minus-reserve default
// (24576 for the 32768 window) would NOT fire. The compaction event lands
// in the session JSONL, the summarization prompt carries the task text
// (the mechanism that folds it into the rolling summary on real runs),
// and the post-compaction projection still renders the obligations
// ledger block at level 0 and keeps the latest tool result (protected
// tail). Without the env the same session does not compact at all.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
// CompactionSettings.forWindow(32768): reserve 8192 → the DEFAULT
// trigger is 24576 estimated tokens. The bench trigger sits far below.
final _defaultTrigger = _window - 8192;
const _benchTriggerTokens = 6000;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

const _taskMarker = 'build the mips interpreter';
const _ledgerText = 'always run the full test suite before pushing';
const _toolResultMarker = 'latest seed tool result';
const _checkpointReply = 'BENCH CHECKPOINT: the mips task stays open; '
    'folded context summarized here.';

/// A structured-compaction-aware fake stream: judge calls (the
/// context-hygiene judge prompt) answer `[]` (hide nothing — the passes
/// proceed deterministically), checkpoint calls answer the canned
/// summary, real turns answer sequentially.
final class _CompactionAwareStream {
  final answers = <String>[];
  final contexts = <Context>[];
  var _answered = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final prompt = [
      for (final m in context.messages)
        switch (m) {
          UserMessage() => messageText(m),
          AssistantMessage() =>
            m.content.whereType<TextContent>().map((b) => b.text).join(),
          _ => '',
        },
    ].join('\n');
    // ignore: avoid_print
    print('REQ#${contexts.length} msgs=${context.messages.length} '
        'sys=${(context.systemPrompt ?? '').substring(0, 60)} '
        'prompt=${prompt.substring(0, prompt.length < 300 ? prompt.length : 300)}');
    final String reply;
    if (prompt.contains('context-hygiene judge')) {
      reply = '[]';
    } else if (prompt.contains('Write a checkpoint')) {
      reply = _checkpointReply;
    } else {
      reply = answers[_answered++ % answers.length];
    }
    final stream = AssistantMessageEventStream();
    for (final event in textTurn(reply)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// Seeds a resumed session whose estimate (~6.6k tokens) sits BETWEEN
  /// the bench trigger (6000) and the default one (24576): the task text
  /// rides the first user message, the obligations ledger carries one
  /// open rule, a valid tool pair (call + result) is the NEWEST records —
  /// the protected tail at compaction time.
  Future<MemoryExecutionEnv> seedBetweenTriggers(String name) async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (suite pattern).
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    await seed.appendMessage(
      UserMessage.text('TASK $_taskMarker; keep the ledger; ${'task ' * 120}'),
    );
    await seed.appendCustomEntry(
      customType: obligationsLedgerRecordType,
      data: [
        {
          'id': 'obl-test-1',
          'kind': 'owner-rule',
          'text': _ledgerText,
          'sourceRecordId': 'rec-1',
          'createdAt': DateTime.utc(2026).toIso8601String(),
          'status': 'open',
        },
      ],
    );
    for (var i = 0; i < 26; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
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
        content: [const TextContent(text: _toolResultMarker)],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    return env;
  }

  AgentCli cli(
    MemoryExecutionEnv env,
    _CompactionAwareStream stream, {
    Map<String, String> environment = const {
      'FAH_COMPACT_TRIGGER_TOKENS': '$_benchTriggerTokens',
    },
  }) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'bench-trigger-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
    ),
    io: io,
    environment: environment,
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
      final stream = _CompactionAwareStream()
        ..answers.addAll(['first answer', 'second answer', 'third answer']);
      final agent = cli(env, stream);

      final run = agent.run();
      // Sanity at the source: the seeded projection sits between the two
      // triggers — only the bench trigger can fire here.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final seeded = await repo.open(
        (await repo.list(cwd: '/work')).single,
      );
      final seededEstimate = estimateContextTokens(
        await seeded.buildContextMessages(),
      ).tokens;
      expect(seededEstimate, greaterThan(_benchTriggerTokens));
      expect(seededEstimate, lessThanOrEqualTo(_defaultTrigger));

      io.sendLine('go');
      await waitForIt(
        () => stream.contexts.length >= 5 && !agent.isBusy,
        reason: 'the boot compaction runs and the first turn answers',
      );
      io.sendLine('/exit');
      await run;

      // The auto-compaction ran and was announced.
      expect(io.out.toString(), contains('auto-compacted'));

      // AC3: the compaction event is VISIBLE in the session JSONL — the
      // structured checkpoint record (and/or hidden ranges) landed.
      final session = await repo.open(
        (await repo.list(cwd: '/work')).single,
      );
      final entries = await session.getEntries();
      expect(
        entries.whereType<CompactCheckpointRecord>(),
        isNotEmpty,
        reason: 'a checkpoint record must land in the session file',
      );

      // The summarization prompt carried the task text — the mechanism
      // that folds it into the rolling summary on real runs.
      final summaryRequestHadTask = stream.contexts.any(
        (context) => context.messages.any(
          (message) =>
              message is UserMessage &&
              messageText(message).contains(_taskMarker),
        ),
      );
      expect(summaryRequestHadTask, isTrue);

      // AC3: the post-compaction projection renders the obligations
      // block at level 0 and keeps the latest tool result (protected
      // tail).
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
      expect(projectedText, contains(_ledgerText));
      expect(projectedText, contains(_toolResultMarker));

      // Every turn request stayed under the DEFAULT trigger — the bench
      // cap bounded the whole run's context.
      for (final context in stream.contexts) {
        expect(
          requestTokensOf(context),
          lessThanOrEqualTo(_defaultTrigger),
          reason: 'a request rode an over-default-trigger context',
        );
      }
    },
  );

  test(
    'without the env the same session does NOT compact (byte-identical '
    'default behavior)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedBetweenTriggers('bench-trigger-target');
      final stream = _CompactionAwareStream()
        ..answers.addAll(['first answer', 'second answer']);
      final agent = cli(env, stream, environment: {});

      final run = agent.run();
      io.sendLine('go');
      await waitForIt(
        () => stream.contexts.isNotEmpty && !agent.isBusy,
        reason: 'the first turn answers without a compaction',
      );
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), isNot(contains('auto-compacted')));
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.open((await repo.list(cwd: '/work')).single);
      final entries = await session.getEntries();
      expect(entries.whereType<CompactCheckpointRecord>(), isEmpty);
      expect(entries.whereType<HiddenRangeRecord>(), isEmpty);
      expect(entries.whereType<CompactionRecord>(), isEmpty);
    },
  );
}
