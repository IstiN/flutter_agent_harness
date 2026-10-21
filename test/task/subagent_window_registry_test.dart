/// gh-1742 — truthful child context pressure:
///
/// - AC2: children resolve their window from the SHARED per-model
///   registry — a test that mutates the registry post-"detection", spawns
///   a child, and asserts the child's `windowTokens` equals the
///   registered value (the repro of the 131,072-advertised-vs-478k-served
///   asymmetry), with `contextWindowCap` honored for children too.
/// - AC5: a child whose observed usage (`input + cacheRead`) already
///   exceeds `window − headroom` at the boundary runs a FORCED compaction
///   pass even when the estimate-based `shouldCompact` is false — proven
///   by the summarizer stream being invoked (a non-forced pass returns
///   before any compactor LLM call) while every real request estimate
///   stayed under the trigger.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

/// The catalog window the "endpoint" advertises (the fictitious one).
const _catalogWindow = 4000;

/// What the provider really serves, published into the registry by the
/// (simulated) live detection.
const _registeredWindow = 478000;

final _model = Model(
  id: 'child-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _catalogWindow,
  maxTokens: 4096,
);

final _fakeTime = DateTime.utc(2026, 9, 15, 12, 0, 0);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  int input = 0,
  int cacheRead = 0,
  int? totalTokens,
}) {
  final observed = input + cacheRead;
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage(
      input: input,
      output: 0,
      cacheRead: cacheRead,
      cacheWrite: 0,
      // OpenAI-compatible gateways exist whose `total_tokens` excludes the
      // cached prefix — the estimate anchor then reads far under the real
      // accepted context (observed = input + cacheRead).
      totalTokens: totalTokens ?? observed,
      cost: const UsageCost(),
    ),
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted text turn whose assistant message reports usage.
List<AssistantMessageEvent> _usageTurn(
  String text, {
  int input = 0,
  int cacheRead = 0,
  int? totalTokens,
}) {
  final partial = _assistant(
    content: [TextContent(text: text)],
    input: input,
    cacheRead: cacheRead,
    totalTokens: totalTokens,
  );
  return [
    StartEvent(partial: partial),
    TextStartEvent(contentIndex: 0, partial: partial),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn ending in one tool call, optionally carrying usage.
List<AssistantMessageEvent> _toolTurn(
  String callId, {
  int input = 0,
  int cacheRead = 0,
  int? totalTokens,
}) {
  final call = ToolCall(id: callId, name: 'read', arguments: const {});
  final partial = _assistant(
    content: [call],
    stopReason: StopReason.toolUse,
    input: input,
    cacheRead: cacheRead,
    totalTokens: totalTokens,
  );
  return [
    StartEvent(partial: partial),
    ToolCallStartEvent(contentIndex: 0, partial: partial),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// A read-tier tool returning a fixed-size payload (fattens the transcript
/// with hideable content).
AgentTool _fatTool(String name, int payloadChars) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('fat:${'x' * payloadChars}'),
  );
}

/// A fake [StreamFunction] answering the structured compaction engine's
/// judge/checkpoint calls plus scripted child turns keyed on the last user
/// text. Compaction LLM calls are counted and NOT recorded in [contexts].
final class _ScriptedStream {
  _ScriptedStream();

  final contexts = <Context>[];
  int compactionCalls = 0;

  /// The Model each compaction LLM call rode (the smol/main summarizer
  /// wiring — the gh-1742 review round 1, comment 6 assertion target).
  final List<Model> compactionModels = [];

  /// Scripted real-child turn FACTORIES keyed on a substring of the last
  /// user text; each entry fires at most once. Falls back to a plain text
  /// turn.
  final Map<String, List<AssistantMessageEvent> Function()> rules = {};
  final Set<String> _usedRules = {};

  int get calls => contexts.length;

  /// The text the next turn is keyed on: the last user message, or —
  /// after a tool call — the last tool result's text.
  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is ToolResultMessage) {
        return message.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n');
      }
      if (message is UserMessage) {
        final content = message.content;
        if (content is String) return content;
        if (content is List<ContentBlock>) {
          return content.whereType<TextContent>().map((b) => b.text).join('\n');
        }
      }
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final system = context.systemPrompt ?? '';
    if (system.contains('context-hygiene judge')) {
      compactionCalls++;
      compactionModels.add(model);
      // ignore: avoid_print
      print('DEBUG judge model window=' + model.contextWindow.toString() + ' id=' + model.id);
      final seqs = RegExp(r'^\[(\d+)\]', multiLine: true)
          .allMatches(lastUserText(context))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      return _streamOf(_usageTurn(jsonEncode(seqs)));
    }
    if (system.contains('context checkpoint assistant')) {
      compactionCalls++;
      compactionModels.add(model);
      // ignore: avoid_print
      print('DEBUG ckpt model window=' + model.contextWindow.toString() + ' id=' + model.id + ' sys=[' + system.substring(0, 60) + ']');
      return _streamOf(_usageTurn('checkpoint: earlier work summarized'));
    }
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final text = lastUserText(context);
    for (final entry in rules.entries) {
      if (text.contains(entry.key) && _usedRules.add(entry.key)) {
        return _streamOf(entry.value());
      }
    }
    return _streamOf(_usageTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

final class _Wiring {
  _Wiring({
    ContextWindowRegistry? registry,
    int? contextWindowCap,
    ModelRolesResolver? rolesResolver,
    _ScriptedStream? scriptedStream,
    int fatChars = 2400,
  }) : stream = scriptedStream ?? _ScriptedStream() {
    manager = SubagentManager(
      parentSessionId: 'parent-session',
      clock: () => _fakeTime,
    )..mailboxPrefix = 'parent-session';
    executor = TaskExecutor(
      childTools: [_fatTool('read', fatChars)],
      streamFunction: () => stream.call,
      model: () => _model,
      registry: TaskAgentRegistry([
        const TaskAgentDefinition(
          name: 'worker',
          description: 'tiny worker',
          systemPrompt: 'w',
        ),
      ]),
      semaphore: Semaphore(4),
      store: AgentOutputStore(),
      subagentManager: manager,
      contextWindowRegistry: registry,
      contextWindowCap: contextWindowCap,
      rolesResolver: rolesResolver,
      childSessionFactory: (parentId, childId) => repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': _model.id,
          },
        ),
      ),
      childSessionOpener: jsonlChildSessionOpener(env),
    );
  }

  final env = MemoryExecutionEnv(cwd: '/work');
  late final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final _ScriptedStream stream;
  late final SubagentManager manager;
  late final TaskExecutor executor;

  Future<TaskSingleResult> spawn(String name, String taskMarker) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: 'worker', task: taskMarker),
      index: 0,
      context: '',
    );
  }

  /// Waits out the fire-and-forget transcript flush (the real session is
  /// attached to the handle when it lands).
  Future<void> settle(String id) async {
    final placeholder = '${manager.parentSessionId}/$id';
    for (var i = 0; i < 1000; i++) {
      if (manager[id]!.sessionId != placeholder) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('child session for "$id" never attached');
  }

  Future<List<SessionRecord>> sessionRecords(String id) async {
    final path = manager[id]!.sessionId;
    final storage = await JsonlSessionStorage.open(env, path);
    return storage.getEntries();
  }
}

void main() {
  group('AC2: children resolve the window from the shared registry', () {
    test('registry published after "detection" → the child rides the '
        'registered window, not the catalog one', () async {
      final registry = ContextWindowRegistry();
      final wiring = _Wiring(registry: registry);
      // The live detection lands BEFORE the spawn (the CLI published it
      // via _replaceModelLimits / _applyDetectedContextWindow).
      registry.publish(
        model: _model,
        window: _registeredWindow,
        source: ContextWindowSource.endpointReport,
      );
      await wiring.spawn('w1', 'registry-window');
      final handle = wiring.manager['w1']!;
      // The repro of the 131,072-vs-478k asymmetry: the child's
      // compaction basis is the REGISTERED window, not the catalog
      // 4000 the wiring model still carries.
      expect(handle.windowTokens, _registeredWindow);
    });

    test('without a registry entry the child falls back to the carried '
        'window (byte-identical legacy behavior)', () async {
      final wiring = _Wiring(registry: ContextWindowRegistry());
      await wiring.spawn('w1', 'no-entry');
      expect(wiring.manager['w1']!.windowTokens, _catalogWindow);
    });

    test(
      'contextWindowCap is honored for children too (clamps down)',
      () async {
        final registry = ContextWindowRegistry();
        registry.publish(
          model: _model,
          window: _registeredWindow,
          source: ContextWindowSource.endpointReport,
        );
        final wiring = _Wiring(registry: registry, contextWindowCap: 2000);
        await wiring.spawn('w1', 'capped');
        // The owner cap wins in whichever direction it points.
        expect(wiring.manager['w1']!.windowTokens, 2000);
      },
    );

    test(
      'the child loop GUARD rides the capped window too (gh-1742 review '
      'round 1, comment 2)',
      () async {
        // The registry raise forks the two child-side bases when the
        // owner clamps down: compaction resolves
        // effectiveContextWindow(registered, cap), but a child Agent
        // built WITHOUT the cap guards against the raw registered value.
        // Here the served window is 478k and the owner caps at 200
        // tokens — every child request is grossly over the CAPPED basis,
        // so the mid-turn guard must refuse BEFORE the first request is
        // sent. With the uncapped guard this request goes out (and the
        // run completes normally).
        final registry = ContextWindowRegistry();
        registry.publish(
          model: _model,
          window: _registeredWindow,
          source: ContextWindowSource.endpointReport,
        );
        final wiring = _Wiring(registry: registry, contextWindowCap: 200);
        final result = await wiring.spawn('guarded', 'over-capped');
        expect(
          wiring.stream.contexts,
          isEmpty,
          reason:
              'the child guard must refuse at the capped basis before any '
              'request is sent (an uncapped guard sends against 478k)',
        );
        // The run surfaces the guard's terminal, not a silent success:
        // the flushed transcript's last assistant message carries the
        // exhausted marker.
        await wiring.settle('guarded');
        final records = await wiring.sessionRecords('guarded');
        final messages = records
            .whereType<MessageRecord>()
            .map((record) => record.message)
            .toList();
        expect(
          messages.any(
            (message) =>
                message is AssistantMessage &&
                isContextWindowExhaustedError(message.errorMessage),
          ),
          isTrue,
          reason:
              'no over-window guard terminal in the transcript '
              '(${result.status}, ${messages.length} messages)',
        );
      },
    );
  });

  group('AC5: observed-over-headroom forces the compaction pass', () {
    test(
      'observed over window − headroom with the estimate under the trigger '
      '→ the compactor runs (forced), the estimate alone would not',
      () async {
        final wiring = _Wiring(registry: ContextWindowRegistry());
        // forWindow(4000): reserve 1024 → trigger 2976.
        const trigger = _catalogWindow - 1024;

        // Turn 1: tool call (usage-less). Tool result fattens the
        // transcript. Turn 2: another tool call carrying the gateway
        // report — total_tokens 100 (excludes the cached prefix), real
        // accepted context = input 100 + cacheRead 3400 = 3500 > 2976.
        // The boundary before turn 3 must force the pass: the estimate
        // anchors on total_tokens (100) and stays far under the trigger.
        wiring.stream.rules.addAll({
          // Turn 1: tool call (usage-less).
          'forced-pass': () => _toolTurn('c1'),
          // Turn 2 (keyed on the fattened tool result): another tool call
          // carrying the gateway report — total_tokens 100 (excludes the
          // cached prefix), real accepted context =
          // 100 input + 3400 cacheRead = 3500 > 2976.
          'fat:': () =>
              _toolTurn('c2', input: 100, cacheRead: 3400, totalTokens: 100),
        });
        final result = await wiring.executor.runSpawn(
          item: const TaskItem(
            name: 'forced',
            agent: 'worker',
            task: 'forced-pass',
          ),
          index: 0,
          context: '',
        );
        expect(result.status, TaskSpawnStatus.completed);

        for (final context in wiring.stream.contexts) {
          final estimate = estimateRequestTokens(
            context.messages,
            systemPrompt: context.systemPrompt,
            tools: context.tools ?? const [],
          );
          expect(
            estimate,
            lessThan(trigger),
            reason:
                'the estimate channel must stay under the trigger for '
                'this repro (got $estimate)',
          );
        }
        // A non-forced pass early-returns BEFORE any compactor LLM call
        // when the estimate is under the trigger — these calls prove the
        // pass was forced by the observed channel.
        expect(
          wiring.stream.compactionCalls,
          greaterThanOrEqualTo(1),
          reason:
              'the observed-over-headroom channel must force the '
              'compaction pass',
        );
        // The child session gained a compaction record (structured
        // engine: hidden ranges / checkpoints; classic: CompactionRecord).
        await wiring.settle('forced');
        final records = await wiring.sessionRecords('forced');
        expect(
          records.any(
            (record) =>
                record is HiddenRangeRecord ||
                record is CompactCheckpointRecord ||
                record is CompactionRecord,
          ),
          isTrue,
          reason: 'no compaction record landed in the child session',
        );
      },
    );

    test('observed usage alone under the trigger stays quiet', () async {
      final wiring = _Wiring(registry: ContextWindowRegistry());
      // Same gateway shape, but the real accepted context (600) is under
      // the trigger: no compaction call, no record.
      wiring.stream.rules.addAll({
        'quiet-observed': () => _toolTurn('c1'),
        'fat:': () =>
            _toolTurn('c2', input: 300, cacheRead: 300, totalTokens: 300),
      });
      final result = await wiring.executor.runSpawn(
        item: const TaskItem(
          name: 'quiet',
          agent: 'worker',
          task: 'quiet-observed',
        ),
        index: 0,
        context: '',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(wiring.stream.compactionCalls, 0);
      await wiring.settle('quiet');
      final records = await wiring.sessionRecords('quiet');
      expect(
        records.any(
          (record) =>
              record is HiddenRangeRecord ||
              record is CompactCheckpointRecord ||
              record is CompactionRecord,
        ),
        isFalse,
      );
      // The observation is still stamped on the handle (AC6 basis).
      expect(wiring.manager['quiet']!.observedTokens, 600);
    });

    test(
      'the pressure stamp carries the observed channel (AC6 basis)',
      () async {
        final registry = ContextWindowRegistry();
        final wiring = _Wiring(registry: registry);
        await wiring.executor.runSpawn(
          item: const TaskItem(
            name: 'stamped',
            agent: 'worker',
            task: 'stamped',
          ),
          index: 0,
          context: '',
        );
        final handle = wiring.manager['stamped']!;
        expect(handle.estTokens, isNotNull);
        expect(handle.windowTokens, _catalogWindow);
        // No registry entry → the window is unverified (AC6's badge basis).
        expect(handle.windowVerified, isFalse);
        // The transcript's last assistant message reported no context → no
        // observation.
        expect(handle.observedTokens, isNull);
      },
    );
  });

  group('the smol summarizer resolves the registered window (gh-1742 '
      'review round 1, comment 6)', () {
    test('compaction LLM calls ride the smol model WITH the registered '
        'window, not the stale catalog one', () async {
      final registry = ContextWindowRegistry();
      // A smol chain entry carrying a WRONG catalog window — exactly the
      // copilot-1M-vs-256k-kimi shape the registry exists for. (The
      // provider must be a catalog kind the resolver knows; the copilot
      // spec is the one the review cites.)
      const smolRef = ModelRef(
        provider: 'anthropic',
        modelId: 'test-smol',
        contextWindow: 400,
        maxTokens: 256,
      );
      final stream = _ScriptedStream();
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: {'smol': [smolRef]},
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {'ANTHROPIC_API_KEY': 'k'},
        streamFactory: (kind, apiKey) => stream.call,
      );
      final wiring = _Wiring(
        registry: registry,
        rolesResolver: resolver,
        scriptedStream: stream,
        // Fat enough that the structured engine's own estimate clears its
        // trigger — the hide pass (and its judge call) must actually run,
        // otherwise the run short-circuits with zero passes and the
        // assertion below is vacuous.
        fatChars: 16000,
      );
      // The detection lands for the SMOL identity before the spawn.
      final smol = resolver.resolveRole(smolModelRole)!;
      registry.publish(
        model: smol.model,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      // The AC5 forced-pass repro (observed over the 400-catalog
      // trigger): the structured engine's judge/checkpoint calls ride
      // the smol chain.
      wiring.stream.rules.addAll({
        'forced-pass': () => _toolTurn('c1'),
        'fat:': () =>
            _toolTurn('c2', input: 100, cacheRead: 3400, totalTokens: 100),
      });
      final result = await wiring.spawn('smolwin', 'forced-pass');
      expect(result.status, TaskSpawnStatus.completed);
      expect(
        wiring.stream.compactionCalls,
        greaterThanOrEqualTo(1),
        reason: 'the forced pass must have run a compaction LLM call',
      );
      for (final model in wiring.stream.compactionModels) {
        expect(
          model.contextWindow,
          478000,
          reason:
              '${model.id}: the smol summarizer must resolve the '
              'REGISTERED window (the checkpoint payload budget and '
              'summarizerWindow mis-bound on the stale catalog 400)',
        );
      }
    });
  });
}
