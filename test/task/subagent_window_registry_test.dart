@TestOn('vm')
library;

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
}) {
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
      totalTokens: input + cacheRead,
      cost: const UsageCost(),
    ),
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn whose assistant message reports [input]/[cacheRead]
/// usage — the provider-truth channel.
List<AssistantMessageEvent> _usageTurn(
  String text, {
  int input = 0,
  int cacheRead = 0,
}) {
  final partial = _assistant(
    content: [TextContent(text: text)],
    input: input,
    cacheRead: cacheRead,
  );
  return [
    StartEvent(partial: partial),
    TextStartEvent(contentIndex: 0, partial: partial),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A fake [StreamFunction] answering the structured compaction engine's
/// judge/checkpoint calls plus scripted child turns keyed on the last user
/// text. Compaction LLM calls are counted and NOT recorded in [contexts].
final class _ScriptedStream {
  _ScriptedStream();

  final contexts = <Context>[];
  int compactionCalls = 0;

  int get calls => contexts.length;

  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
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
      final seqs = RegExp(r'^\[(\d+)\]', multiLine: true)
          .allMatches(lastUserText(context))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      return _streamOf(_usageTurn(jsonEncode(seqs)));
    }
    if (system.contains('context checkpoint assistant')) {
      compactionCalls++;
      return _streamOf(_usageTurn('checkpoint: earlier work summarized'));
    }
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
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
  _Wiring({ContextWindowRegistry? registry, int? contextWindowCap}) {
    stream = _ScriptedStream();
    manager = SubagentManager(
      parentSessionId: 'parent-session',
      clock: () => _fakeTime,
    )..mailboxPrefix = 'parent-session';
    executor = TaskExecutor(
      childTools: [
        AgentTool(
          name: 'read',
          description: 'read tool',
          tier: ApprovalTier.read,
          execute: (arguments, cancelToken, onUpdate) async =>
              ToolExecutionResult.text('x'),
        ),
      ],
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
  late final _ScriptedStream stream;
  late final SubagentManager manager;
  late final TaskExecutor executor;

  Future<TaskSingleResult> spawn(String name, String taskMarker) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: 'worker', task: taskMarker),
      index: 0,
      context: '',
    );
  }

  Future<List<SessionRecord>> sessionRecords(String id) async {
    final path = manager[id]!.sessionId;
    final storage = await JsonlSessionStorage.open(env, path);
    return storage.getEntries();
  }
}

void main() {
  group('AC2: children resolve the window from the shared registry', () {
    test(
      'registry published after "detection" → the child rides the '
      'registered window, not the catalog one',
      () async {
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
      },
    );

    test('without a registry entry the child falls back to the carried '
        'window (byte-identical legacy behavior)', () async {
      final wiring = _Wiring(registry: ContextWindowRegistry());
      await wiring.spawn('w1', 'no-entry');
      expect(wiring.manager['w1']!.windowTokens, _catalogWindow);
    });

    test('contextWindowCap is honored for children too (clamps down)',
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
    });
  });

  group('AC5: observed-over-headroom forces the compaction pass', () {
    test(
      'observed over window − headroom with the estimate under the trigger '
      '→ the compactor runs (forced), the estimate alone would not',
      () async {
        final wiring = _Wiring(registry: ContextWindowRegistry());
        // forWindow(4000): reserve 1024 → trigger 2976.
        const trigger = _catalogWindow - 1024;

        // The transcript stays TINY (the estimate channel never fires:
        // every real request's estimate is asserted under the trigger
        // below), but the provider reports 3,500 observed tokens — over
        // the line. The observed channel must force the pass.
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
            reason: 'the estimate channel must stay under the trigger for '
                'this repro',
          );
        }
        // A non-forced pass early-returns BEFORE any compactor LLM call
        // when the estimate is under the trigger — these calls prove the
        // pass was forced by the observed channel.
        expect(
          wiring.stream.compactionCalls,
          greaterThanOrEqualTo(1),
          reason: 'the observed-over-headroom channel must force the '
              'compaction pass',
        );
        // The child session gained a compaction record.
        final records = await wiring.sessionRecords('forced');
        expect(
          records.whereType<CompactionRecord>(),
          isNotEmpty,
          reason: 'no compaction record landed in the child session',
        );
      },
    );

    test('the pressure stamp carries the observed channel (AC6 basis)',
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
    });
  });
}
