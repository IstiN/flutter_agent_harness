@TestOn('vm')
library;

/// Issue #1924 — truthful child numbers + bounded child compaction failure.
///
/// The 2026-10-26 session 01a06102 shape: children "finished" with 667k /
/// 377k / 372k / 358k "contexts" on a 204.8k model. The headline figures
/// are LIFETIME cumulative billed usage (input+output+cacheWrite across
/// every request), not live context — the displays must say so, the live
/// ctx% must ride every row, and a child whose boundary compaction keeps
/// failing must latch off (bounded budget) with an actionable
/// parent-visible error instead of silently riding toward the wall.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/subagent_board.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

/// The token estimate of the report-size contract's footprint in a child
/// request (issue #1829): the contract rides the system prompt AND both
/// injected tool descriptions (reply also carries a manifest paragraph
/// beyond the contract), so the window carries the full measured growth.
final int _contractTokens = () {
  final mgr = SubagentManager(parentSessionId: 'p', maxReplyChars: 8000);
  final descriptions = [
    for (final tool in subagentMonitoringTools(
      manager: mgr,
      currentSubagentId: () => null,
    ))
      if (tool.name == 'reply' || tool.name == 'agent_message')
        tool.description,
  ];
  final contract = deliverableChunkContract(8000).length;
  final growthChars =
      contract +
      descriptions
          .map((d) => d.length - contract < 0 ? 0 : d.length - contract)
          .fold<int>(0, (a, b) => a + b);
  return (growthChars / 4).ceil();
}();

/// Tiny window, same calibration as subagent_compaction_test.dart: the
/// compaction trigger lands at window − reserve, well under the window.
final _model = Model(
  id: 'child-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 4300 + _contractTokens,
  maxTokens: 4096,
);

final _fakeTime = DateTime.utc(2026, 10, 27, 9, 0, 0);

/// Per-turn billed usage that pumps the LIFETIME total far past the window
/// while pricing the CONTEXT honestly (input 300, no cacheRead): the
/// 667k-on-204.8k shape — cumulative ≫ window, live context fine.
const _lifetimeUsage = Usage(
  input: 300,
  output: 50,
  cacheRead: 0,
  cacheWrite: 9000,
  totalTokens: 9350,
  cost: UsageCost(),
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text, {Usage usage = Usage.zero}) {
  final empty = _assistant(usage: usage);
  final partial = _assistant(
    content: [TextContent(text: text)],
    usage: usage,
  );
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(
  String toolName,
  String callId, {
  Usage usage = Usage.zero,
}) {
  final empty = _assistant(usage: usage);
  final call = ToolCall(id: callId, name: toolName, arguments: const {});
  final partial = _assistant(
    content: [call],
    stopReason: StopReason.toolUse,
    usage: usage,
  );
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: empty),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : rules = List.of(rules);

  final List<_Rule> rules;

  final contexts = <Context>[];
  int compactionCalls = 0;

  int get calls => contexts.length;

  int requestTokens(Context context) => estimateRequestTokens(
    context.messages,
    systemPrompt: context.systemPrompt,
    tools: context.tools ?? const [],
  );

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
    if (system.contains('context-hygiene judge') ||
        system.contains('context checkpoint assistant')) {
      compactionCalls++;
      final seqs = RegExp(r'^\[(\d+)\]', multiLine: true)
          .allMatches(lastUserText(context))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      return _streamOf(_textTurn(jsonEncode(seqs)));
    }
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final text = lastUserText(context);
    for (final rule in rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        final events = rule.turns.removeAt(0);
        return _streamOf(events);
      }
    }
    return _streamOf(_textTurn('done'));
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

AgentTool _fatTool(String name, int payloadChars) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('r${'x' * payloadChars}'),
  );
}

final class _Wiring {
  _Wiring({
    List<_Rule> rules = const [],
    List<AgentTool>? childTools,
    int payloadChars = 2400,
    this.rolesResolver,
  }) {
    stream = _ScriptedStream(rules);
    manager = SubagentManager(
      parentSessionId: 'parent-session',
      clock: () => _fakeTime,
    )..mailboxPrefix = 'parent-session';
    final registry = TaskAgentRegistry([
      const TaskAgentDefinition(
        name: 'worker',
        description: 'tiny worker',
        systemPrompt: 'w',
      ),
    ]);
    executor = TaskExecutor(
      childTools: childTools ?? [_fatTool('read', payloadChars)],
      streamFunction: () => stream.call,
      model: () => _model,
      registry: registry,
      semaphore: Semaphore(4),
      store: AgentOutputStore(),
      rolesResolver: rolesResolver,
      subagentManager: manager,
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
  final ModelRolesResolver? rolesResolver;

  /// A configured-but-uncredentialed `roles.smol` chain: every child
  /// compaction pass throws [UnusableRoleChainException] at role
  /// resolution — before any LLM call, deterministically, every time.
  static ModelRolesResolver brokenSmolResolver() => ModelRolesResolver(
    config: ModelRolesConfig(
      roles: {
        smolModelRole: [
          const ModelRef(
            provider: 'anthropic',
            modelId: 'test-smol',
            contextWindow: 2000,
            maxTokens: 128,
          ),
        ],
      },
    ),
    secrets: const {},
  );

  Future<TaskSingleResult> spawn(String name, String taskMarker) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: 'worker', task: taskMarker),
      index: 0,
      context: '',
    );
  }

  Future<void> settle(String id) async {
    final placeholder = '${manager.parentSessionId}/$id';
    for (var i = 0; i < 1000; i++) {
      if (manager[id]!.sessionId != placeholder) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('child session for "$id" never attached');
  }

  List<AgentTool> monitoringTools() => subagentMonitoringTools(
    manager: manager,
    readMessages: jsonlChildMessageReader(env),
    resumeChild: executor.resumeChild,
  );

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    final result = await monitoringTools()
        .firstWhere((t) => t.name == toolName)
        .execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }
}

void main() {
  group(
    'AC-truthful: the 667k/204.8k shape reads as lifetime, not context',
    () {
      test(
        'cumulative usage far above the window with live ctx under it: '
        'compaction fires, requests stay in-window, rows label both bases',
        () async {
          final w = _Wiring(
            rules: [
              (
                match: 'grow',
                turns: [
                  _toolTurn('read', 'c1', usage: _lifetimeUsage),
                  _toolTurn('read', 'c2', usage: _lifetimeUsage),
                  _toolTurn('read', 'c3', usage: _lifetimeUsage),
                  _toolTurn('read', 'c4', usage: _lifetimeUsage),
                  _toolTurn('read', 'c5', usage: _lifetimeUsage),
                  _toolTurn('read', 'c6', usage: _lifetimeUsage),
                  _textTurn('finished', usage: _lifetimeUsage),
                ],
              ),
            ],
          );
          final result = await w.spawn('sixsixseven', 'grow the context');
          expect(
            result.status,
            TaskSpawnStatus.completed,
            reason: result.error,
          );
          final handle = w.manager['sixsixseven']!;

          // The misread shape reproduced: lifetime billed usage FAR above the
          // window (the owner-facing "667k" against a 204.8k model), while the
          // child never sent an over-window request and compacted in time.
          expect(handle.tokens, greaterThan(_model.contextWindow));
          expect(handle.compactions, greaterThanOrEqualTo(1));
          expect(
            w.stream.contexts.map(w.stream.requestTokens),
            everyElement(lessThanOrEqualTo(_model.contextWindow)),
          );
          expect(handle.estTokens, isNotNull);
          expect(handle.estTokens!, lessThanOrEqualTo(_model.contextWindow));

          // The status row names the basis: lifetime cumulative vs live ctx %.
          expect(handle.statusLine, contains('lifetime'));
          expect(handle.statusLine, contains('% ctx'));
          expect(handle.statusLine, isNot(contains('OVER WINDOW')));

          // task_status detail names the basis explicitly.
          final detail = await w.execute('task_status', {'id': 'sixsixseven'});
          expect(detail, contains('lifetime — cumulative billed usage'));
          expect(detail, isNot(contains('OVER WINDOW')));

          // The board row carries the live ctx% in its preview.
          final record = subagentRecordOf(handle);
          expect(record.preview, startsWith('[~'));
          expect(record.preview, isNot(contains('OVER WINDOW')));
        },
      );
    },
  );

  group('AC-over-window-marker: an over-wall child is marked, not muted', () {
    test('est at/over the window renders OVER WINDOW in every surface', () {
      final handle =
          SubagentHandle(
              id: 'over',
              name: 'over',
              agentType: 'worker',
              sessionId: 's',
              createdAt: _fakeTime.toIso8601String(),
              task: 't',
            )
            ..estTokens = 220000
            ..windowTokens = 204800;
      expect(handle.contextPressureText, contains('OVER WINDOW'));
      expect(handle.statusLine, contains('OVER WINDOW'));

      // Under the window: no marker.
      handle.estTokens = 100000;
      expect(handle.contextPressureText, isNot(contains('OVER WINDOW')));

      // The compaction-failure stamp rides the row and the JSON round-trip.
      handle.compactionError = 'child compaction failed 3 consecutive passes';
      expect(handle.statusLine, contains('compaction failing'));
      final restored = SubagentHandle.fromJson(handle.toJson());
      expect(restored.compactionError, handle.compactionError);

      // The board preview carries the marker too.
      final record = subagentRecordOf(handle..estTokens = 220000);
      expect(record.preview, contains('OVER WINDOW'));
    });
  });

  group('AC-bounded-failure: #1914-in-child latches with a parent-visible '
      'error', () {
    test('repeated failing passes latch off after the budget, stamp the '
        'handle, and stop being attempted', () async {
      // Two fat turns stay under the trigger: the spawn never compacts.
      // The compaction model role is broken (configured smol chain with no
      // credentials) — every pass dies at role resolution, the real-world
      // shape of "compaction keeps failing inside a child".
      final w = _Wiring(
        rolesResolver: _Wiring.brokenSmolResolver(),
        rules: [
          (
            match: 'grow',
            turns: [
              _toolTurn('read', 'c1'),
              _toolTurn('read', 'c2'),
              _textTurn('base done'),
            ],
          ),
        ],
      );
      final result = await w.spawn('latchy', 'grow the context');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('latchy');
      final handle = w.manager['latchy']!;
      expect(handle.compactions, 0, reason: 'precondition: no pass ran');
      expect(handle.compactionError, isNull);

      // Resume #1 carries a message big enough to cross the trigger: the
      // compact-then-deliver pass runs and fails (broken role) — the
      // parent-visible stamp appears from the FIRST failure.
      await w.execute('task_send', {'id': 'latchy', 'message': 'y' * 6000});
      expect(handle.status, SubagentStatus.completed);
      expect(handle.compactionError, isNotNull);
      expect(handle.compactionError, contains('task_resume'));

      // Keep resuming until the latch trips (budget: 3 consecutive
      // failures); every resume still completes — a bounded compaction
      // failure never kills the child's run.
      int? failureCount() {
        final match = RegExp(
          r'failed (\d+) consecutive',
        ).firstMatch(handle.compactionError ?? '');
        return match == null ? null : int.parse(match.group(1)!);
      }

      for (var i = 0; i < 3 && (failureCount() ?? 0) < 3; i++) {
        await w.execute('task_send', {
          'id': 'latchy',
          'message': 'more ${'y' * 200}',
        });
        expect(handle.status, SubagentStatus.completed);
      }
      expect(failureCount(), greaterThanOrEqualTo(3));
      expect(handle.compactionError, contains('latched'));
      final detail = await w.execute('task_status', {'id': 'latchy'});
      expect(detail, contains('\ncompaction: child compaction failed'));
      expect(detail, contains('task_resume'));

      // Bounded: once latched, a resume probes EXACTLY ONE pass (the
      // recovery funnel) and boundary passes stop — one resume advances
      // the count by exactly one.
      final before = failureCount()!;
      await w.execute('task_send', {
        'id': 'latchy',
        'message': 'more ${'y' * 200}',
      });
      expect(handle.status, SubagentStatus.completed);
      expect(failureCount(), before + 1);
      expect(handle.compactions, 0);
    });
  });

  group('AC-gate-declines: a healthy no-op pass never reads as failure', () {
    test('resume probe where only + incoming crosses the trigger: engine '
        'gate declines on the transcript basis — no stamp, no count',
        () async {
      // Two fat turns leave the transcript ~2.2k, under the ~3.3k trigger
      // (healthy boundary compaction never fires on it).
      final w = _Wiring(
        rules: [
          (
            match: 'grow',
            turns: [
              _toolTurn('read', 'c1'),
              _toolTurn('read', 'c2'),
              _textTurn('base done'),
            ],
          ),
        ],
      );
      final result = await w.spawn('declined', 'grow the context');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('declined');
      final handle = w.manager['declined']!;
      expect(handle.compactions, 0, reason: 'precondition: under trigger');
      expect(handle.compactionError, isNull);

      // The resume's incoming message (~1500t) crosses the trigger on the
      // executor's basis (transcript + incoming) — but the transcript
      // ALONE stays under it, so the engine's own gate declines the pass.
      await w.execute('task_send', {'id': 'declined', 'message': 'y' * 6000});
      expect(handle.status, SubagentStatus.completed);

      // The declined no-op is a HEALTHY non-attempt: no failure stamp, no
      // counter — the false alarm the review caught. (The resumed run's
      // own in-run boundary may legitimately compact once the message has
      // landed in state; that is a healthy pass, not a probe failure.)
      expect(handle.compactionError, isNull);
      expect(handle.statusLine, isNot(contains('compaction failing')));
      final detail = await w.execute('task_status', {'id': 'declined'});
      expect(detail, isNot(contains('\ncompaction: ')));
    });
  });
}
