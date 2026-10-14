// THROWAWAY debug repro — not part of the deliverable.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  test('engine repro', timeout: const Timeout(Duration(minutes: 5)), () async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await session.appendMessage(
      UserMessage.text('TASK build the mips interpreter; ${'task ' * 120}'),
    );
    for (var i = 0; i < 26; i++) {
      await session.appendMessage(UserMessage.text('filler$i ${'x' * 1000}'));
    }
    await session.appendMessage(
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
    await session.appendMessage(
      ToolResultMessage(
        toolCallId: 'call-seed-1',
        toolName: 'read',
        content: [const TextContent(text: 'tool result body')],
        isError: false,
        timestamp: DateTime.utc(2026),
      ),
    );
    final messages = await session.buildContextMessages();
    // ignore: avoid_print
    print('seed messages=${messages.length}');
    final settings = withCompactionTriggerTokens(
      CompactionSettings.forWindow(32768),
      window: 32768,
      triggerTokens: 6000,
    );
    // ignore: avoid_print
    print('settings reserve=${settings.reserveTokens} '
        'keep=${settings.keepRecentTokens}');
    // --- CLI-parity open path: windowed open + boundary walk ---
    final listed = await repo.list(cwd: '/work');
    final windowed = await repo.open(listed.single, windowed: true);
    final resident = await windowed.ensureCompactionBoundaryResident(
      tokenBudget: 6000,
    );
    // ignore: avoid_print
    print('resident=$resident');
    final windowedMessages = await windowed.buildContextMessages();
    // ignore: avoid_print
    print('windowed messages=${windowedMessages.length}');
    final model = Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 32768,
      maxTokens: 4096,
    );
    final state = AgentState(model: model)
      ..messages = windowedMessages.isEmpty ? messages : windowedMessages;
    final engineSession = windowedMessages.isEmpty ? session : windowed;
    // CLI parity: the boot gate measures transcript + system/tools
    // overhead (~11k > trigger) while the transcript alone (5818) is not.
    state.systemPrompt = 'S' * 8000;
    state.tools = [
      for (var i = 0; i < 12; i++)
        Tool(
          name: 'tool$i',
          description: 'd' * 200,
          parameters: {},
        ),
    ];
    // ignore: avoid_print
    print('cliBasisTokens=${estimateRequestTokens(state.messages, systemPrompt: state.systemPrompt, tools: state.tools)}');
    // ignore: avoid_print
    print('requestTokens='
        '${estimateRequestTokens(state.messages, systemPrompt: null, tools: const [])}');
    final compactor = StructuredCompactor(
      session: engineSession,
      state: state,
      window: 32768,
      settings: settings,
      judge: (ledgerText) async {
        // ignore: avoid_print
        print('JUDGE ledgerLen=${ledgerText.length}');
        return '[]';
      },
      summarize: (request) async {
        // ignore: avoid_print
        print('SUMMARIZE promptLen=${request.prompt.length} '
            'filler=${request.prompt.contains('filler')}');
        return SummarizationResult.success('BENCH CHECKPOINT canned.');
      },
      checkpointPrompt: defaultCompactionPrompts.structuredCheckpoint,
    );
    final ok = await compactor.run();
    // ignore: avoid_print
    print('ok=$ok messagesAfter=${state.messages.length}');
    for (final e in await session.getEntries()) {
      if (e is CompactCheckpointRecord) {
        // ignore: avoid_print
        print('CKPT covers=${e.coversRecordIds.length} '
            'text=${e.text.substring(0, 30)}');
      }
    }
  });
}
