@TestOn('vm')
library;

/// gh-2492 C2 — pinned steering for task subagents.
///
/// The task child's own session file must carry `segment_pin` records
/// (`SegmentPinRecord`, `session_record.dart`) for:
/// - the task prompt record (the child's first user message) — pinned once;
/// - every steering delivery (the parent's mail as it becomes user
///   records) — the newest delivery's records pinned, the previous
///   delivery's records released (one steering delivery pinned at a time);
/// - a resumed child's pre-card session gains "ensure pins" once: the
///   first prompt record and the newest steering record, never un-hiding
///   anything already hidden.
///
/// REG-6: `isSyntheticUserText` semantics are untouched — mail stays
/// data; pins are the only protection channel.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

final _model = Model(
  id: 'pin-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 200000,
  maxTokens: 4096,
);

final _fakeTime = DateTime.utc(2026, 11, 28, 12, 0, 0);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

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

/// A fake stream: one scripted tool turn per call until the script is
/// empty, then a final text turn.
AssistantMessageEventStream _streamOf(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

/// A read-tier probe tool that enqueues one steering message into the
/// running child's inbox (the parent's `task_send` shape) and returns.
AgentTool _steerProbeTool(SubagentManager manager, String text) {
  return AgentTool(
    name: 'steer_probe',
    description: 'steer probe',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async {
      final childId = activeSubagentId();
      if (childId == null) {
        return ToolExecutionResult.text('no child scope');
      }
      await manager.enqueueMessage(
        childId,
        SubagentMessage(
          fromId: 'parent-main',
          text: text,
          sentAt: _fakeTime.toIso8601String(),
        ),
        capText: false,
      );
      return ToolExecutionResult.text('queued');
    },
  );
}

/// The pinned-record-id replay over a session record list (last pin per
/// id wins) — the same semantics the structured projection applies.
Set<String> _pinnedIds(List<SessionRecord> records) {
  final pinned = <String>{};
  for (final record in records) {
    if (record is SegmentPinRecord) {
      record.pinned
          ? pinned.addAll(record.recordIds)
          : pinned.removeAll(record.recordIds);
    }
  }
  return pinned;
}

List<MessageRecord> _messageRecords(List<SessionRecord> records) => [
  for (final record in records)
    if (record is MessageRecord) record,
];

String _textOf(MessageRecord record) {
  final message = record.message;
  if (message is! UserMessage) return '';
  final content = message.content;
  if (content is String) return content;
  if (content is List<ContentBlock>) {
    return content.whereType<TextContent>().map((b) => b.text).join('\n');
  }
  return '';
}

/// The executor + manager + JSONL session wiring, mirroring how
/// `AgentCli` wires `TaskToolConfig`.
final class _Wiring {
  _Wiring({int toolTurns = 0, List<String> steerTexts = const []}) {
    manager = SubagentManager(
      parentSessionId: 'parent-session',
      clock: () => _fakeTime,
    )..mailboxPrefix = 'parent-session';
    final registry = TaskAgentRegistry([
      const TaskAgentDefinition(
        name: 'worker',
        description: 'worker',
        systemPrompt: 'w',
      ),
    ]);
    executor = TaskExecutor(
      childTools: [
        _steerProbeTool(manager, steerTexts.firstOrNull ?? 'steer one'),
      ],
      streamFunction: () => _scriptedRun(toolTurns),
      model: () => _model,
      registry: registry,
      semaphore: Semaphore(4),
      store: AgentOutputStore(),
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
  late final SubagentManager manager;
  late final TaskExecutor executor;

  Future<TaskSingleResult> spawn(String name, String task) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: 'worker', task: task),
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

  Future<List<SessionRecord>> sessionRecords(String id) async {
    final path = manager[id]!.sessionId;
    final storage = await JsonlSessionStorage.open(env, path);
    return storage.getEntries();
  }

  /// Awaits the child's flush chain, then reads the settled records
  /// (pins append inside the chained flush; reading before it drains
  /// would race the unawaited final flush).
  Future<List<SessionRecord>> settledRecords(String id) async {
    await executor.settleChildFlushForTest(id);
    return sessionRecords(id);
  }
}

/// N scripted tool turns followed by a final text turn.
StreamFunction _scriptedRun(int toolTurns) {
  var call = 0;
  return (Model model, Context context, {CancelToken? cancelToken}) {
    call++;
    return _streamOf(
      call <= toolTurns
          ? _toolTurn('steer_probe', 'c$call')
          : _textTurn('done'),
    );
  };
}

void main() {
  group('C2 fresh spawn: the task prompt record is pinned', () {
    test(
      'the child session gains a segment_pin for the first user record',
      () async {
        final w = _Wiring();
        final result = await w.spawn('pinner', 'grow the pins');
        expect(result.status, TaskSpawnStatus.completed, reason: result.error);
        await w.settle('pinner');
        final records = await w.settledRecords('pinner');
        final messages = _messageRecords(records);
        expect(messages, isNotEmpty);
        final promptRecord = messages.firstWhere(
          (record) => record.message is UserMessage,
        );
        final pins = [
          for (final record in records)
            if (record is SegmentPinRecord) record,
        ];
        expect(
          pins,
          isNotEmpty,
          reason: 'the task prompt record stays unpinned',
        );
        expect(
          _pinnedIds(records),
          contains(promptRecord.id),
          reason: 'the task prompt record must be pinned',
        );
      },
    );

    test('the pin names exactly the prompt record (no blanket pins)', () async {
      final w = _Wiring(toolTurns: 1);
      final result = await w.spawn('exact', 'grow the pins');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('exact');
      final records = await w.settledRecords('exact');
      final pins = [
        for (final record in records)
          if (record is SegmentPinRecord) record,
      ];
      // Every pin event that turns records ON must be small: it names at
      // most the prompt record and one steering delivery's records —
      // never a whole-file pin.
      for (final pin in pins.where((pin) => pin.pinned)) {
        expect(
          pin.recordIds.length,
          lessThanOrEqualTo(2),
          reason: 'a pin event names at most prompt + one steering record',
        );
      }
    });
  });

  group('C2 steering deliveries: newest pinned, previous released', () {
    test('two deliveries leave exactly the newest steering pinned', () async {
      final w = _Wiring(toolTurns: 3, steerTexts: ['steer one']);
      final result = await w.spawn('steered', 'grow the steering');
      expect(result.status, TaskSpawnStatus.completed, reason: result.error);
      await w.settle('steered');
      final records = await w.settledRecords('steered');
      final messages = _messageRecords(records);
      final steeringRecords = messages
          .where((record) => _textOf(record).startsWith('from parent-main:'))
          .toList();
      expect(
        steeringRecords.length,
        greaterThanOrEqualTo(1),
        reason: 'the probe enqueues steering the child drains at a boundary',
      );
      final pinned = _pinnedIds(records);
      final promptRecord = messages.firstWhere(
        (record) =>
            record.message is UserMessage &&
            !_textOf(record).startsWith('from '),
      );
      expect(pinned, contains(promptRecord.id));
      // The NEWEST steering record is pinned; the older ones are not.
      expect(pinned, contains(steeringRecords.last.id));
      for (final record in steeringRecords.take(steeringRecords.length - 1)) {
        expect(
          pinned,
          isNot(contains(record.id)),
          reason: 'older steering folds — one steering pinned at a time',
        );
      }
    });
  });

  group('C2 resume belt: ensure pins over a pre-card session', () {
    test('a resumed pre-card session gains pins for the prompt and the '
        'newest steering record, hiding nothing', () async {
      final w = _Wiring();
      final manager = w.manager;
      await manager.register(
        id: 'legacy',
        name: 'legacy',
        agentType: 'worker',
        task: 'legacy child',
      );
      await manager.update('legacy', status: SubagentStatus.failed);
      final session = await w.repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {'agent': 'subagent', 'id': 'legacy'},
        ),
      );
      // The pre-card shape: a task prompt, some turns, one steering
      // delivery — and NO segment_pin records anywhere.
      await session.appendMessage(UserMessage.text('do the legacy task'));
      await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'working')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'pin-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendMessage(
        UserMessage.text('from parent-main: steer the legacy child'),
      );
      final path = (await session.getMetadata()).path;
      await manager.attachSession('legacy', path);

      await w.executor.resumeChild('legacy', 'resume steering one');
      final records = await w.settledRecords('legacy');
      final messages = _messageRecords(records);
      final promptRecord = messages.firstWhere(
        (record) => _textOf(record) == 'do the legacy task',
      );
      final legacySteering = messages.lastWhere(
        (record) =>
            _textOf(record) == 'from parent-main: steer the legacy child',
      );
      final pinned = _pinnedIds(records);
      expect(pinned, contains(promptRecord.id));
      // The newest steering record after the resume is the RESUME prompt
      // itself (the joined warm-wake mail); the pre-card steering record
      // may be released by it — one steering pinned at a time — but must
      // never be HIDDEN (no hidden_range may name it).
      final resumeSteering = messages
          .where(
            (record) =>
                _textOf(record).startsWith('from ') &&
                record.timestamp.isAfter(legacySteering.timestamp),
          )
          .toList();
      expect(resumeSteering, isNotEmpty);
      expect(pinned, contains(resumeSteering.last.id));
      final hidden = <String>{};
      for (final record in records) {
        if (record is HiddenRangeRecord) hidden.addAll(record.recordIds);
      }
      expect(
        hidden,
        isNot(
          anyOf(contains(promptRecord.id), contains(resumeSteering.last.id)),
        ),
      );
    });
  });

  group('C2 REG-6: mail stays synthetic data', () {
    test('isSyntheticUserText semantics unchanged (no predicate change)', () {
      expect(isSyntheticUserText('from parent-main: do x'), isTrue);
      expect(isSyntheticUserText('do the task'), isFalse);
    });
  });

  group('C2 IT-4: pins survive compaction', () {
    test(
      'deterministic hide pass never buries the pinned records',
      () => _itPinsSurviveDeterministicHide(),
    );
  });
}

/// IT-4 (gh-2492 C2): across hide passes the task prompt record and the
/// newest steering record stay visible — every tier drops picks that
/// touch a pinned id (judge validation, the deterministic fallback, LRU
/// re-hide). The deterministic path runs here: the stream answers the
/// structured engine's judge with unparseable text, so the pass falls
/// back to the mechanical oldest-first hide.
/// Returns the test body future (declared OUTSIDE `main` so the runner
/// never sees a nested `test()` call).
Future<void> _itPinsSurviveDeterministicHide() async {
  final env = MemoryExecutionEnv(cwd: '/work');
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final manager = SubagentManager(
    parentSessionId: 'parent-session',
    clock: () => _fakeTime,
  )..mailboxPrefix = 'parent-session';
  final registry = TaskAgentRegistry([
    const TaskAgentDefinition(
      name: 'worker',
      description: 'worker',
      systemPrompt: 'w',
    ),
  ]);
  // Tiny window: the fat tool turns cross the compaction trigger
  // mid-run; the judge answer is unparseable text, forcing the
  // deterministic fallback hide.
  final tinyModel = Model(
    id: 'tiny-model',
    api: 'test-api',
    provider: 'test-provider',
    baseUrl: 'https://example.test',
    contextWindow: 6200,
    maxTokens: 4096,
  );
  var call = 0;
  AssistantMessageEventStream streamFn(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    call++;
    final system = context.systemPrompt ?? '';
    if (system.contains('context-hygiene judge')) {
      return _streamOf(_textTurn('not json at all'));
    }
    if (system.contains('context checkpoint assistant')) {
      return _streamOf(_textTurn('checkpoint text'));
    }
    final empty = _assistant();
    // Turn 1 steers (the delivery pins); turns 2-4 fill the context
    // with fat tool results until the hide crosses.
    if (call >= 1 && call <= 4) {
      final toolCall = ToolCall(
        id: 'c$call',
        name: call == 1 ? 'steer_probe' : 'fat_probe',
        arguments: const {},
      );
      final partial = _assistant(
        content: [toolCall],
        stopReason: StopReason.toolUse,
      );
      return _streamOf([
        StartEvent(partial: empty),
        ToolCallStartEvent(contentIndex: 0, partial: empty),
        ToolCallEndEvent(contentIndex: 0, toolCall: toolCall, partial: empty),
        DoneEvent(reason: StopReason.toolUse, message: partial),
      ]);
    }
    return _streamOf(_textTurn('done'));
  }

  final executor = TaskExecutor(
    childTools: [
      _steerProbeTool(manager, 'steer across compaction'),
      // The payload that fills the context.
      AgentTool(
        name: 'fat_probe',
        description: 'fat probe',
        tier: ApprovalTier.read,
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('r${'x' * 6000}'),
      ),
    ],
    streamFunction: () => streamFn,
    model: () => tinyModel,
    registry: registry,
    semaphore: Semaphore(4),
    store: AgentOutputStore(),
    subagentManager: manager,
    childSessionFactory: (parentId, childId) => repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work',
        metadata: {
          'agent': 'subagent',
          'id': childId,
          'parent': parentId,
          'model': tinyModel.id,
        },
      ),
    ),
    childSessionOpener: jsonlChildSessionOpener(env),
  );
  final result = await executor.runSpawn(
    item: TaskItem(
      name: 'pinned-grower',
      agent: 'worker',
      task: 'grow across compactions',
    ),
    index: 0,
    context: '',
  );
  expect(result.status, TaskSpawnStatus.completed, reason: result.error);
  final path = manager['pinned-grower']!.sessionId;
  await executor.settleChildFlushForTest('pinned-grower');
  final storage = await JsonlSessionStorage.open(env, path);
  final records = await storage.getEntries();

  // The pass ran (records folded: hidden ranges or checkpoint covers —
  // both must skip pinned ids; checkpoints never swallow them, #1379).
  final hidden = <String>{};
  for (final record in records) {
    if (record is HiddenRangeRecord) hidden.addAll(record.recordIds);
    if (record is CompactCheckpointRecord) {
      hidden.addAll(record.coversRecordIds);
      hidden.add(record.firstRecordId);
      hidden.add(record.lastRecordId);
    }
  }
  expect(hidden, isNotEmpty, reason: 'the fixture must cross the trigger');

  final messages = _messageRecords(records);
  // The task prompt record: the FIRST user message (its text carries
  // the assignment).
  final promptRecord = messages.firstWhere(
    (record) =>
        record.message is UserMessage &&
        _textOf(record).contains('grow across compactions'),
  );
  final steeringRecords = messages
      .where((record) => _textOf(record).startsWith('from parent-main:'))
      .toList();
  expect(steeringRecords, isNotEmpty);
  final pinned = _pinnedIds(records);
  expect(pinned, contains(promptRecord.id));
  expect(pinned, contains(steeringRecords.last.id));
  // The belt: no hide pass buried the pinned records.
  expect(hidden, isNot(contains(promptRecord.id)));
  expect(hidden, isNot(contains(steeringRecords.last.id)));
}
