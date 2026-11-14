/// gh-2101 — pass metrics (duration / cost / cache-hit) end to end:
///
/// - the structured engine folds every judge/digest call's metered usage
///   into its pass receipts (one cache-affine run: all calls share one
///   routing session id, `short` retention) and stamps the pass's
///   wall-clock duration;
/// - the hooks adapter carries the metrics onto [AutoCompactorPass] —
///   the surface the CLI one-line and details reports render;
/// - legacy runs (usage-less fakes) keep the metrics null — byte-compatible
///   reports.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart'
    show streamFunctionHideJudge;
import 'package:test/test.dart';

AssistantMessage _assistant(
  String text, {
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'p',
    model: 'm1',
    usage: usage,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

AssistantMessageEventStream _streamOf(AssistantMessage message) {
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: message));
  stream.push(DoneEvent(reason: StopReason.stop, message: message));
  stream.end();
  return stream;
}

/// Metered usage one scripted call reports: 100 uncached input, 900 cache
/// reads, 10 output, $0.05.
Usage _metered() => Usage(
  input: 100,
  output: 10,
  cacheRead: 900,
  cacheWrite: 0,
  totalTokens: 1010,
  cost: const UsageCost(total: 0.05),
);

/// A scripted StreamFunction: answers the judge's ledger prompt with
/// `['1, 2, 3']` picks and checkpoint prompts with a summary line. Records
/// the active [StreamCacheRouting] per call and reports [_metered] usage.
final class _ScriptedRun {
  final routings = <({String? sessionId, String? cacheRetention})?>[];
  final prompts = <String>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    routings.add(StreamCacheRouting.current);
    final prompt = context.messages
        .map(
          (m) => switch (m) {
            final UserMessage u => switch (u.content) {
              final String text => text,
              final List<Object> blocks => blocks
                  .whereType<TextContent>()
                  .map((b) => b.text)
                  .join('\n'),
              _ => '',
            },
            _ => '',
          },
        )
        .join('\n');
    prompts.add(prompt);
    final answer = prompt.contains('<conversation>')
        ? 'checkpoint: the login crash investigation so far'
        : '[1, 2, 3]';
    return _streamOf(_assistant(answer, usage: _metered()));
  }
}

ToolResultMessage _result(String callId, String text) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'read',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

/// The fat synthetic session (mirror of structured_pass_report_test.dart's
/// fixture): user ask, three fat read pairs, closing user ask — enough to
/// push the 8k window over pressure for hide + checkpoint passes.
Future<Session> _buildSession(JsonlSessionRepo repo) async {
  AssistantMessage assistant(String text, {List<ToolCall>? calls}) =>
      AssistantMessage(
        content: [TextContent(text: text), ...?calls],
        api: 'anthropic-messages',
        provider: 'p',
        model: 'm1',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
  await session.appendMessage(UserMessage.text('fix the login crash'));
  for (var i = 0; i < 3; i++) {
    await session.appendMessage(
      assistant(
        'step $i',
        calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
      ),
    );
    await session.appendMessage(_result('c$i', 'payload $i ${'x' * 16000}'));
    await session.appendMessage(assistant('analysis $i findings'));
  }
  await session.appendMessage(UserMessage.text('what was the exact error?'));
  return session;
}

final class _Hooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) {}
}

const _window = 8000;
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

Future<void> _runStructured(
  Session session,
  AgentState state,
  StreamFunction stream,
  _Hooks hooks,
) async {
  const model = Model(
    id: 'm1',
    api: 'anthropic-messages',
    provider: 'p',
    baseUrl: 'http://localhost:1',
    contextWindow: _window,
    maxTokens: 4096,
  );
  await AutoCompactorFactory(
    session: session,
    state: state,
    window: _window,
    settings: _settings,
    sources: AutoCompactorSources(
      smolStream: stream,
      smolModel: model,
      mainStream: stream,
      mainModel: model,
    ),
    hooks: hooks,
    engine: CompactionEngine.structured,
  ).run();
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  test('structured pass receipts carry duration, cost and cache-hit '
      'usage; the whole run shares one routing id', () async {
    final scripted = _ScriptedRun();
    final session = await _buildSession(repo);
    final entries = await session.getEntries();
    final state = AgentState(
      model: const Model(
        id: 'm1',
        api: 'anthropic-messages',
        provider: 'p',
        baseUrl: 'http://localhost:1',
        contextWindow: _window,
        maxTokens: 4096,
      ),
      messages: [
        for (final r in entries)
          if (r is MessageRecord) r.message,
      ],
    );
    final hooks = _Hooks();
    await _runStructured(session, state, scripted.call, hooks);

    final metered = hooks.passes
        .where((p) => p.usage != null && p.usage!.calls > 0)
        .toList();
    expect(metered, isNotEmpty,
        reason: 'at least the judged hide pass reports usage');
    for (final pass in metered) {
      expect(pass.durationMs, isNotNull,
          reason: 'measured passes carry the one-line duration');
      expect(pass.usage!.calls, greaterThanOrEqualTo(1));
      // Every scripted call reports 900 cache reads — the pass totals fold
      // per call (2 calls → 1800).
      expect(pass.usage!.cacheReadTokens, greaterThanOrEqualTo(900));
      expect(pass.usage!.costUsd, greaterThan(0));
      expect(pass.usage!.cacheHitRatio, closeTo(0.9, 0.05));
    }
    // The cache-affine run: judge AND digest calls share one bucket.
    expect(scripted.routings, hasLength(greaterThanOrEqualTo(2)));
    expect(
      scripted.routings.every((r) => r!.sessionId == scripted.routings.first!
          .sessionId),
      isTrue,
      reason: 'one routing id per compaction run',
    );
    expect(
      scripted.routings.every((r) => r!.cacheRetention == 'short'),
      isTrue,
      reason: 'the deliberate short-retention policy rides every call',
    );
  });

  test('multi-call passes fold usage across all their calls', () async {
    final scripted = _ScriptedRun();
    final session = await _buildSession(repo);
    final entries = await session.getEntries();
    final state = AgentState(
      model: const Model(
        id: 'm1',
        api: 'anthropic-messages',
        provider: 'p',
        baseUrl: 'http://localhost:1',
        contextWindow: _window,
        maxTokens: 4096,
      ),
      messages: [
        for (final r in entries)
          if (r is MessageRecord) r.message,
      ],
    );
    final hooks = _Hooks();
    await _runStructured(session, state, scripted.call, hooks);
    // The checkpoint pass summarizing a range makes ONE summarizer call; a
    // judged hide pass makes ONE judge call — across the run the receipts'
    // usage calls must add up to the calls the scripted stream saw with
    // usage (every call is metered).
    final totalCalls = hooks.passes.fold<int>(
      0,
      (sum, p) => sum + (p.usage?.calls ?? 0),
    );
    expect(totalCalls, scripted.routings.length,
        reason: 'every metered call lands in exactly one pass receipt');
  });

  test('legacy usage-less runs keep the metrics null (byte-compatible '
      'reports)', () async {
    AssistantMessageEventStream plain(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) => _streamOf(_assistant('[1, 2]'));
    final session = await _buildSession(repo);
    final entries = await session.getEntries();
    final state = AgentState(
      model: const Model(
        id: 'm1',
        api: 'anthropic-messages',
        provider: 'p',
        baseUrl: 'http://localhost:1',
        contextWindow: _window,
        maxTokens: 4096,
      ),
      messages: [
        for (final r in entries)
          if (r is MessageRecord) r.message,
      ],
    );
    final hooks = _Hooks();
    await _runStructured(session, state, plain, hooks);
    for (final pass in hooks.passes) {
      expect(pass.usage, isNull);
    }
    // Duration stays measured — it is wall-clock, not provider-reported.
    expect(
      hooks.passes.any((p) => p.durationMs != null),
      isTrue,
    );
  });

  test('the judge adapter forwards usage into the shared run ledger',
      () async {
    final ledger = CompactionUsageAccumulator();
    const model = Model(
      id: 'm1',
      api: 'anthropic-messages',
      provider: 'p',
      baseUrl: 'http://localhost:1',
      contextWindow: _window,
      maxTokens: 4096,
    );
    final judge = streamFunctionHideJudge(
      (m, c, {cancelToken}) =>
          _streamOf(_assistant('[1]', usage: _metered())),
      model,
      system: 'judge',
      onUsage: ledger.add,
    );
    expect(await judge('ledger'), '[1]');
    expect(ledger.snapshot().calls, 1);
    expect(ledger.snapshot().cacheReadTokens, 900);
  });
}
