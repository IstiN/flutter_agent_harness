// gh-1604 items 2+3 — the bench compaction trigger wired through the real
// CLI gates (AC2/AC3 mechanism layer).
//
// `FAH_COMPACT_TRIGGER_TOKENS` fires the auto-compaction at an absolute
// context size (here 24000 on a 200k window, where the default formula
// fires only at 183616) once the run's context crosses it — mirroring a
// bench trial that grows past the trigger mid-run. The compaction event
// lands in the session JSONL, the summarization prompt carries the task
// text (the mechanism that folds it into the rolling summary on real
// runs), and the post-compaction projection still renders the
// obligations ledger block and keeps the latest tool result (protected
// tail). Without the env the same session does not compact at all.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 200000;
// CompactionSettings.forWindow(200000): reserve 16384 → the DEFAULT
// trigger is 183616 estimated tokens. The bench trigger sits far below.
final _defaultTrigger = _window - 16384;
const _benchTriggerTokens = 24000;

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
const _checkpointReply =
    'BENCH CHECKPOINT: the mips task stays open; '
    'folded context summarized here.';
// ~10k estimated tokens: pushes the first turn's context past the 24k
// bench trigger while the boot gate (seed ~16k incl. harness overhead)
// stays under it — the compaction fires MID-RUN, the way a bench trial
// grows past the trigger.
final _bigAnswer = 'growth ${'y' * 40000}';

/// A structured-compaction-aware fake stream: judge calls (the
/// context-hygiene judge prompt) answer `[]` (hide nothing — the passes
/// proceed deterministically), checkpoint calls answer the canned
/// summary, real turns answer from [turnAnswers] in order.
final class _CompactionAwareStream {
  final turnAnswers = <String>[];
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
    final String reply;
    if (prompt.contains('context-hygiene judge')) {
      reply = '[]';
    } else if (prompt.contains('Write a checkpoint')) {
      reply = _checkpointReply;
    } else {
      reply = turnAnswers[_answered++ % turnAnswers.length];
    }
    final stream = AssistantMessageEventStream();
    for (final event in textTurn(reply)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// [waitForIt] with a LAZY description: the failure text is built at
/// timeout, so it names the state that actually was reached.
Future<void> waitUntil(
  bool Function() condition,
  String Function() describe,
) async {
  for (var i = 0; i < 5000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${describe()}');
}

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  /// Seeds a resumed session whose transcript (~11k tokens; ~16k with the
  /// harness's own system-prompt/tool overhead) sits UNDER the bench
  /// trigger: the task text rides the first user message, the obligations
  /// ledger carries one open rule, and a valid tool pair (call + result)
  /// is the NEWEST records — the protected tail at compaction time.
  /// The compaction must fire MID-RUN when the big first answer pushes
  /// the context past the trigger — not at boot.
  Future<MemoryExecutionEnv> seedUnderTrigger(String name) async {
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
    for (var i = 0; i < 40; i++) {
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

  /// The agent-turn requests (the compaction judge/checkpoint calls are
  /// filtered out by their own system prompts).
  Iterable<Context> turnRequests(_CompactionAwareStream stream) =>
      stream.contexts.where(
        (context) => (context.systemPrompt ?? '').startsWith('You are Fa'),
      );

  test(
    'the bench trigger fires mid-run where the default would not; the '
    'compaction event lands in the JSONL; obligations + latest tool '
    'result survive',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedUnderTrigger('bench-trigger-target');
      final stream = _CompactionAwareStream()
        ..turnAnswers.addAll([_bigAnswer, 'second answer']);
      final agent = cli(env, stream);

      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () => turnRequests(stream).isNotEmpty && !agent.isBusy,
        () =>
            'turn 1: turns=${turnRequests(stream).length} '
            'calls=${stream.contexts.length}',
      );
      io.sendLine('go');
      await waitUntil(
        () => turnRequests(stream).length >= 2 && !agent.isBusy,
        () =>
            'turn 2: turns=${turnRequests(stream).length} '
            'calls=${stream.contexts.length} '
            'out=${io.out.toString().substring(io.out.length > 2000 ? io.out.length - 2000 : 0)}',
      );
      io.sendLine('/exit');
      await run;

      // The compaction fired MID-RUN (after the first turn), not at boot:
      // the first agent request rode the un-compacted seed — under the
      // DEFAULT trigger (only the bench knob could have fired here).
      final firstTurn = turnRequests(stream).first;
      expect(
        messageText(firstTurn.messages.whereType<UserMessage>().last),
        isNot(contains('compacted into the following summary')),
      );
      expect(
        estimateRequestTokens(
          firstTurn.messages,
          systemPrompt: firstTurn.systemPrompt,
          tools: firstTurn.tools ?? const <Tool>[],
        ),
        lessThanOrEqualTo(_defaultTrigger),
      );
      // The auto-compaction ran and was announced.
      expect(io.out.toString(), contains('auto-compacted'));

      // AC3: the compaction event is VISIBLE in the session JSONL — the
      // structured checkpoint record landed.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.open((await repo.list(cwd: '/work')).single);
      final entries = await session.getEntries();
      expect(
        entries.whereType<CompactCheckpointRecord>(),
        isNotEmpty,
        reason: 'a checkpoint record must land in the session file',
      );

      // The summarization prompt carried the conversation — the task
      // text among it (the mechanism that folds it into the rolling
      // summary on real runs).
      final summaryRequestHadTask = stream.contexts.any(
        (context) => context.messages.any(
          (message) =>
              message is UserMessage &&
              messageText(message).contains(_taskMarker),
        ),
      );
      expect(summaryRequestHadTask, isTrue);

      // AC3: the post-compaction projection renders the obligations
      // block and keeps the latest tool result (protected tail).
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

      // Every agent-turn request after the trigger crossing stayed under
      // the bench cap — the run's context was bounded for the rest of
      // the session.
      for (final (index, context) in turnRequests(stream).indexed) {
        if (index == 0) continue; // the pre-trigger turn
        final tokens = estimateRequestTokens(
          context.messages,
          systemPrompt: context.systemPrompt,
          tools: context.tools ?? const <Tool>[],
        );
        expect(
          tokens,
          lessThanOrEqualTo(_benchTriggerTokens),
          reason: 'turn request #$index rode an over-trigger context',
        );
      }
    },
  );

  test(
    'without the env the same session does NOT compact (byte-identical '
    'default behavior)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await seedUnderTrigger('bench-trigger-target');
      final stream = _CompactionAwareStream()
        ..turnAnswers.addAll([_bigAnswer, 'second answer']);
      final agent = cli(env, stream, environment: {});

      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () => turnRequests(stream).isNotEmpty && !agent.isBusy,
        () =>
            'turn 1: turns=${turnRequests(stream).length} '
            'calls=${stream.contexts.length}',
      );
      io.sendLine('go');
      await waitUntil(
        () => turnRequests(stream).length >= 2 && !agent.isBusy,
        () =>
            'turn 2: turns=${turnRequests(stream).length} '
            'calls=${stream.contexts.length} '
            'out=${io.out.toString().substring(io.out.length > 2000 ? io.out.length - 2000 : 0)}',
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

  group('bench trigger vs an explicit compactionSettings override '
      '(gh-1604 rework)', () {
    // Construction-only CLI: the precedence is a pure getter over the
    // config + env, no run needed.
    AgentCli agent({
      CompactionSettings? compactionSettings,
      Map<String, String> environment = const {
        'FAH_COMPACT_TRIGGER_TOKENS': '$_benchTriggerTokens',
      },
    }) => AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: '[REDACTED:Sensitive Value]',
        env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell()),
        sessionRoot: '/sessions',
        sessionName: 'bench-trigger-target',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionSettings: compactionSettings,
      ),
      io: io,
      environment: environment,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );

    test('an explicit config pin wins over the env knob — the knob '
        'retunes the DEFAULTS, it never rewrites a pinned section', () {
      const pin = CompactionSettings(
        enabled: true,
        reserveTokens: 500,
        keepRecentTokens: 600,
      );
      final settings = agent(
        compactionSettings: pin,
      ).effectiveCompactionSettingsForTest;
      expect(settings.reserveTokens, 500);
      expect(settings.keepRecentTokens, 600);
    });

    test('an explicit enabled:false pin stays disabled — the env knob '
        'cannot re-enable compaction', () {
      const pin = CompactionSettings(
        enabled: false,
        reserveTokens: 16384,
        keepRecentTokens: 200,
      );
      final settings = agent(
        compactionSettings: pin,
      ).effectiveCompactionSettingsForTest;
      expect(settings.enabled, isFalse);
      expect(settings.reserveTokens, 16384);
      expect(settings.keepRecentTokens, 200);
    });

    test('without a pin the env knob applies (regression anchor)', () {
      final settings = agent().effectiveCompactionSettingsForTest;
      expect(shouldCompact(_benchTriggerTokens, _window, settings), isFalse);
      expect(shouldCompact(_benchTriggerTokens + 1, _window, settings), isTrue);
    });

    test('without a pin and without the env the defaults apply '
        '(byte-identical legacy)', () {
      final settings = agent(
        environment: {},
      ).effectiveCompactionSettingsForTest;
      final defaults = CompactionSettings.forWindow(_window);
      expect(settings.enabled, defaults.enabled);
      expect(settings.reserveTokens, defaults.reserveTokens);
      expect(settings.keepRecentTokens, defaults.keepRecentTokens);
    });
  });
}
