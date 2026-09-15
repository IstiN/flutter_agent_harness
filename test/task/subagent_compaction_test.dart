@TestOn('vm')
library;

/// Issue #439 — subagent context exhaustion: threshold-based proactive
/// compaction on child turns (`prepareNextTurn`), `task_send`
/// compact-then-deliver, and child context pressure in `task_status`.
///
/// The compaction discipline mirrors the main loop (#387/#388): the
/// over-window guard stays the LAST resort — compaction must free the
/// context at the turn boundary so the wall is never reached.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

/// Tiny window: reserve 1024 → compaction trigger 2976, keep-recent 2048.
const _model = Model(
  id: 'child-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 4000,
  maxTokens: 4096,
);

final _fakeTime = DateTime.utc(2026, 9, 15, 12, 0, 0);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted text-only turn.
List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn ending in one tool call.
List<AssistantMessageEvent> _toolTurn(String toolName, String callId) {
  final empty = _assistant();
  final call = ToolCall(id: callId, name: toolName, arguments: const {});
  final partial = _assistant(content: [call], stopReason: StopReason.toolUse);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: empty),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

/// A fake [StreamFunction] that answers the structured compaction engine's
/// judge and checkpoint calls (dispatched on the system prompt) plus
/// scripted child turns keyed on the last user text. Compaction LLM calls
/// are counted but NOT recorded in [contexts] — only real child requests
/// are, so window assertions stay exact.
final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : rules = List.of(rules);

  final List<_Rule> rules;
  final contexts = <Context>[];
  int compactionCalls = 0;

  int get calls => contexts.length;

  /// The request-size estimate on the ONE basis the loop guard and the
  /// compaction threshold enforce.
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
    if (system.contains('context-hygiene judge')) {
      compactionCalls++;
      // Pick every ledger line; the validator strips protected ids.
      final seqs = RegExp(r'^\[(\d+)\]', multiLine: true)
          .allMatches(lastUserText(context))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      return _streamOf(_textTurn(jsonEncode(seqs)));
    }
    if (system.contains('context checkpoint assistant')) {
      compactionCalls++;
      return _streamOf(_textTurn('checkpoint: earlier work summarized'));
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

/// A read-tier tool returning a fixed-size payload (fattens the transcript).
AgentTool _fatTool(String name, int payloadChars) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('r${'x' * payloadChars}'),
  );
}

/// The executor + manager + JSONL session wiring, mirroring how `AgentCli`
/// wires `TaskToolConfig` (child sessions in a real repo).
final class _Wiring {
  _Wiring({
    List<_Rule> rules = const [],
    List<AgentTool>? childTools,
    ModelRolesResolver? rolesResolver,
    int payloadChars = 2400,
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
      const TaskAgentDefinition(
        name: 'minismol',
        description: 'worker on the smol role',
        systemPrompt: 'w',
        modelRole: smolModelRole,
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

  /// Spawns one child named [name] whose task contains [taskMarker] and
  /// waits for the whole run.
  Future<TaskSingleResult> spawn(
    String name,
    String taskMarker, {
    String agent = 'worker',
  }) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: agent, task: taskMarker),
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

  /// The records in the child's JSONL session file.
  Future<List<SessionRecord>> sessionRecords(String id) async {
    final path = manager[id]!.sessionId;
    final storage = await JsonlSessionStorage.open(env, path);
    return storage.getEntries();
  }

  /// The CLI-equivalent monitoring tools (wiring parity).
  List<AgentTool> monitoringTools() => subagentMonitoringTools(
    manager: manager,
    readMessages: jsonlChildMessageReader(env),
    resumeChild: executor.resumeChild,
  );

  AgentTool tool(String name) =>
      monitoringTools().firstWhere((t) => t.name == name);

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    final result = await tool(toolName).execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }
}

/// The first captured request whose last user text contains [marker].
Context _firstRequest(_ScriptedStream stream, String marker) =>
    stream.contexts.firstWhere(
      (context) => _ScriptedStream.lastUserText(context).contains(marker),
    );

void main() {
  group('AC1+AC6 IT-child-compaction: proactive compaction on child turns', () {
    test(
      'child crossing the threshold mid-task compacts at the turn boundary; '
      'the next request is under-window and the session gains a compaction '
      'record',
      () async {
        // Five fat tool turns (2400 chars ≈ 600t each) cross the 2976t
        // trigger mid-run.
        final w = _Wiring(rules: [
          (
            match: 'grow',
            turns: [
              _toolTurn('read', 'c1'),
              _toolTurn('read', 'c2'),
              _toolTurn('read', 'c3'),
              _toolTurn('read', 'c4'),
              _toolTurn('read', 'c5'),
              _textTurn('finished'),
            ],
          ),
        ]);
        final result = await w.spawn('grower', 'grow the context');
        expect(result.status, TaskSpawnStatus.completed, reason: result.error);
        final handle = w.manager['grower']!;
        expect(handle.compactions, greaterThanOrEqualTo(1));
        expect(handle.lastCompactionFreed, greaterThan(0));
        expect(handle.lastCompactionAt, _fakeTime.toIso8601String());

        // Zero over-window requests; the engine actually ran.
        expect(w.stream.compactionCalls, greaterThanOrEqualTo(1));
        expect(w.stream.calls, greaterThanOrEqualTo(6));
        for (final context in w.stream.contexts) {
          expect(
            w.stream.requestTokens(context),
            lessThanOrEqualTo(_model.contextWindow),
            reason: 'a request exceeded the child window',
          );
        }
        // The last request rides the compacted projection: under the
        // trigger, not merely the window.
        final last = w.stream.contexts.last;
        expect(
          w.stream.requestTokens(last),
          lessThanOrEqualTo(_model.contextWindow - 1024),
        );

        // The child session file carries the compaction records.
        final records = await w.sessionRecords('grower');
        expect(
          records.any(
            (record) =>
                record is HiddenRangeRecord ||
                record is CompactCheckpointRecord,
          ),
          isTrue,
          reason: 'no compaction record landed in the child session',
        );
      },
    );
  });

  group('AC1-E1: steering races boundary compaction', () {
    test('steering sent mid-tool-call is delivered after the boundary '
        'compaction, in-order', () async {
      final gate = Completer<String>();
      final started = Completer<void>();
      final gateTool = AgentTool(
        name: 'gate',
        description: 'gate tool',
        tier: ApprovalTier.read,
        execute: (arguments, cancelToken, onUpdate) async {
          started.complete();
          return ToolExecutionResult.text(await gate.future);
        },
      );
      // The mid-run gate result (12000 chars ≈ 3000t) alone crosses the
      // 2976t trigger: compaction and steering meet at the SAME boundary.
      final w = _Wiring(
        childTools: [gateTool],
        rules: [
          (match: 'grow', turns: [_toolTurn('gate', 'g1')]),
          (match: 'wrap up now', turns: [_textTurn('wrapped up')]),
        ],
      );
      final done = w.spawn('racer', 'grow the context');
      await started.future;
      // The parent steers while the child is mid-tool-call.
      final sendResult = await w.execute('task_send', {
        'id': 'racer',
        'message': 'wrap up now',
      });
      expect(sendResult, contains('queued'));
      gate.complete('r${'x' * 12000}');
      final result = await done;
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);

      final handle = w.manager['racer']!;
      expect(handle.compactions, greaterThanOrEqualTo(1));
      // The steering message reached the child in-order with compaction:
      // the steered request rides the compacted projection (under the
      // trigger), and no request ever exceeded the window.
      final steered = _firstRequest(w.stream, 'wrap up now');
      expect(
        w.stream.requestTokens(steered),
        lessThanOrEqualTo(_model.contextWindow - 1024),
      );
      for (final context in w.stream.contexts) {
        expect(
          w.stream.requestTokens(context),
          lessThanOrEqualTo(_model.contextWindow),
        );
      }
    });
  });

  group('AC2 IT-task-send-compact-then-deliver', () {
    test('task_send to an at-wall child compacts first, delivers, and '
        'reports the freed tokens', () async {
      // Three fat turns (~825t each) land the transcript just UNDER the
      // 2976t trigger — no boundary compaction ran while it lived.
      final w = _Wiring(
        payloadChars: 3300,
        rules: [
          (
            match: 'fill',
            turns: [
              _toolTurn('read', 'c1'),
              _toolTurn('read', 'c2'),
              _toolTurn('read', 'c3'),
              _textTurn('filled'),
            ],
          ),
        ],
      );
      final result = await w.spawn('filled_child', 'fill the context');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('filled_child');
      final handle = w.manager['filled_child']!;
      expect(handle.compactions, 0, reason: 'precondition: never compacted');

      // The follow-up (~1000t) pushes prior + incoming over the trigger:
      // the resume must compact BEFORE the first request.
      final sendResult = await w.execute('task_send', {
        'id': 'filled_child',
        'message': 'follow-up: ${'y' * 4000}',
      });
      expect(sendResult, contains('compacted before delivery'));
      expect(sendResult, contains('freed'));
      expect(handle.compactions, greaterThanOrEqualTo(1));
      expect(handle.lastCompactionFreed, greaterThan(0));
      expect(handle.status, SubagentStatus.completed);

      // The child's first resumed request carries the message and fits
      // the window.
      final first = _firstRequest(w.stream, 'follow-up');
      expect(
        w.stream.requestTokens(first),
        lessThanOrEqualTo(_model.contextWindow),
      );
    });
  });

  group('AC3 UT-status-pressure: child pressure in task_status', () {
    test('detail shows tokens / window % / last compaction; absent is n/a',
        () async {
      final w = _Wiring(rules: [
        (
          match: 'grow',
          turns: [
            _toolTurn('read', 'c1'),
            _toolTurn('read', 'c2'),
            _toolTurn('read', 'c3'),
            _toolTurn('read', 'c4'),
            _toolTurn('read', 'c5'),
            _textTurn('finished'),
          ],
        ),
      ]);
      await w.spawn('pressured', 'grow the context');
      final detail = await w.execute('task_status', {'id': 'pressured'});
      expect(detail, matches(RegExp(r'context: ~\d+/4000 tokens \(\d+%\)')));
      expect(detail, contains('last compaction: freed'));
      expect(detail, contains(_fakeTime.toIso8601String()));
      // The list row carries the window percentage too.
      final list = await w.execute('task_status', {});
      expect(list, contains('% ctx'));

      // A child that never made a request renders honest n/a lines.
      final fresh = _Wiring();
      await fresh.manager.register(
        id: 'fresh_child',
        name: 'fresh_child',
        agentType: 'worker',
        task: 'x',
      );
      final freshDetail = await fresh.execute('task_status', {
        'id': 'fresh_child',
      });
      expect(freshDetail, contains('context: n/a'));
      expect(freshDetail, contains('last compaction: n/a'));
    });
  });

  group('AC4 UT-guard-last-resort: un-shrinkable still fails honestly', () {
    test('a single record over the window trips the guard; task_send '
        'reports the exact failure, the request is never sent', () async {
      final w = _Wiring(payloadChars: 100);
      final result = await w.spawn('small_child', 'fill the context');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('small_child');
      final callsBefore = w.stream.calls;

      // The follow-up alone (40000 chars ≈ 10000t) exceeds the 4000t
      // window: compaction cannot free enough — the guard must refuse
      // BEFORE the request goes out, and the failure must surface.
      final sendResult = await w.execute('task_send', {
        'id': 'small_child',
        'message': 'z' * 40000,
      });
      expect(sendResult, contains('Context window exhausted'));
      expect(sendResult, contains('resume of "small_child" failed'));
      expect(w.stream.calls, callsBefore, reason: 'the request was not sent');
      expect(w.manager['small_child']!.status, SubagentStatus.failed);
    });
  });

  group('AC6 E2E-long-child', () {
    test('a fake-tool child runs past the threshold, compacts mid-run, '
        'completes with zero over-window requests', () async {
      final w = _Wiring(
        payloadChars: 2000,
        rules: [
          (
            match: 'march',
            turns: [
              _toolTurn('read', 'c1'),
              _toolTurn('read', 'c2'),
              _toolTurn('read', 'c3'),
              _toolTurn('read', 'c4'),
              _toolTurn('read', 'c5'),
              _toolTurn('read', 'c6'),
              _textTurn('marched'),
            ],
          ),
        ],
      );
      final result = await w.spawn('marcher', 'march through the files');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      final handle = w.manager['marcher']!;
      expect(handle.compactions, greaterThanOrEqualTo(1));
      expect(
        w.stream.contexts.map(w.stream.requestTokens),
        everyElement(lessThanOrEqualTo(_model.contextWindow)),
      );
    });
  });

  group('E4: thresholds from the child effective window', () {
    test("a smol-role child compacts on its OWN window, not the parent's",
        () async {
      // Window 2000: reserve 500 → trigger 1500, keep-recent 1000.
      final smolStream = _ScriptedStream([
        (
          match: 'grow',
          turns: [
            _toolTurn('read', 'c1'),
            _toolTurn('read', 'c2'),
            _toolTurn('read', 'c3'),
            _toolTurn('read', 'c4'),
            _textTurn('finished'),
          ],
        ),
      ]);
      final resolver = ModelRolesResolver(
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
        secrets: const {'ANTHROPIC_API_KEY': 'k'},
        streamFactory: (kind, apiKey) => smolStream.call,
      );
      final w = _Wiring(rolesResolver: resolver);
      final result = await w.spawn(
        'smol_child',
        'grow the context',
        agent: 'minismol',
      );
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      final handle = w.manager['smol_child']!;
      // The pressure is measured against the CHILD's 2000t window — not
      // the parent's 100000t one — and the compaction fired on it.
      expect(handle.windowTokens, 2000);
      expect(handle.compactions, greaterThanOrEqualTo(1));
      expect(
        smolStream.contexts.map(smolStream.requestTokens),
        everyElement(lessThanOrEqualTo(2000)),
      );
    });
  });
}
