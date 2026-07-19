import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

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

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// Scripted [StreamFunction] replaying pre-recorded turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

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
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// Host persistence seam mirroring the CLI's batch model: messages persist
/// lazily (the test flushes between runs), while the controller flushes the
/// messages it anchors or drops through [sink] on demand.
class _TestHost {
  _TestHost(this.session);

  Session? session;
  var persistedCount = 0;

  CheckpointSessionSink get sink => CheckpointSessionSink(
    session: () => session,
    persistedMessageCount: () => persistedCount,
    persistMessage: (message) async {
      final id = await session!.appendMessage(message);
      persistedCount++;
      return id;
    },
  );

  /// Simulates the host's run-end batch persistence.
  Future<void> flush(Agent agent) async {
    final messages = agent.state.messages;
    for (final message in messages.skip(persistedCount)) {
      await session!.appendMessage(message);
    }
    persistedCount = messages.length;
  }
}

/// A trivial detour tool standing in for read/grep exploration.
AgentTool _probeTool() {
  return AgentTool(
    name: 'probe',
    description: 'Probe something.',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      return ToolExecutionResult.text('probed ${arguments['path']}');
    },
  );
}

void main() {
  late JsonlSessionRepo repo;

  setUp(() {
    repo = JsonlSessionRepo(fs: MemoryFileSystem(), sessionsRoot: '/sessions');
  });

  Future<Session> newSession() {
    return repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  }

  /// Builds an agent + controller over a scripted model. [turns] are replayed
  /// in order; the host sink mirrors CLI persistence.
  Future<({Agent agent, CheckpointRewindController controller, _TestHost host})>
  harness(
    _FakeStreamFunction fake, {
    Session? session,
    bool withSession = true,
  }) async {
    final host = _TestHost(withSession ? session ?? await newSession() : null);
    late final CheckpointRewindController controller;
    final registry = ToolRegistry([_probeTool()]);
    final agent = Agent(
      model: _model,
      systemPrompt: 'test system prompt',
      streamFunction: fake.call,
      toolRegistry: registry,
    );
    controller = CheckpointRewindController(
      agent: agent,
      sink: host.sink,
      onRewindApplied: (count) => host.persistedCount = count,
    );
    registry.registerAll(controller.tools);
    agent.state.tools = registry.tools;
    return (agent: agent, controller: controller, host: host);
  }

  ToolCall checkpointCall([String id = 'c1', String? goal]) =>
      ToolCall(id: id, name: checkpointToolName, arguments: {'goal': ?goal});

  ToolCall rewindCall(String report, [String id = 'c1']) =>
      ToolCall(id: id, name: rewindToolName, arguments: {'report': report});

  ToolCall probeCall(String path, [String id = 'c1']) =>
      ToolCall(id: id, name: 'probe', arguments: {'path': path});

  Future<List<SessionRecord>> activeBranch(Session session) =>
      session.getBranch();

  group('checkpoint tool', () {
    test('result confirms the mark and writes a checkpoint record', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1', 'probe the cache')]),
        _textTurn('done'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('start');

      expect(h.controller.activeCheckpoint, isNotNull);
      expect(h.controller.activeCheckpoint!.messageCount, 3);
      expect(h.controller.activeCheckpoint!.goal, 'probe the cache');

      // The tool result confirms the mark with the current message count.
      final result = h.agent.state.messages[2] as ToolResultMessage;
      final text = result.content.whereType<TextContent>().first.text;
      expect(text, contains('Checkpoint created (message count: 3).'));
      expect(text, contains('Goal: probe the cache'));

      // The checkpoint record sits on the branch right after the checkpoint
      // tool result, carrying the same anchors.
      final session = h.host.session!;
      final branch = await activeBranch(session);
      final record = branch.whereType<CheckpointRecord>().single;
      expect(record.messageCount, 3);
      expect(record.goal, 'probe the cache');
      expect(h.controller.activeCheckpoint!.entryId, record.id);
      expect(branch[branch.indexOf(record) - 1], isA<MessageRecord>());
      // Record round-trips through storage.
      final reloaded = await session.getEntry(record.id);
      expect(reloaded, isA<CheckpointRecord>());
      expect((reloaded! as CheckpointRecord).messageCount, 3);
    });

    test('a second checkpoint while one is active errors', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1', 'first')]),
        _toolTurn([checkpointCall('c2', 'second')]),
        _textTurn('done'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('start');

      final result = h.agent.state.messages.whereType<ToolResultMessage>().last;
      expect(result.isError, isTrue);
      final text = result.content.whereType<TextContent>().first.text;
      expect(text, contains('Checkpoint already active'));
      expect(h.controller.activeCheckpoint!.goal, 'first');
    });
  });

  group('rewind tool guards', () {
    test('rewind without a checkpoint errors with an explanation', () async {
      final fake = _FakeStreamFunction([_textTurn('hi')]);
      final h = await harness(fake);
      final rewind = h.controller.tools.firstWhere(
        (t) => t.name == rewindToolName,
      );
      await expectLater(
        () => rewind.execute({'report': 'findings'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No active checkpoint'),
          ),
        ),
      );
    });

    test('rewind with a blank report errors', () async {
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1')]),
        _textTurn('done'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('start');

      final rewind = h.controller.tools.firstWhere(
        (t) => t.name == rewindToolName,
      );
      await expectLater(
        () => rewind.execute({'report': '   '}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Report cannot be empty'),
          ),
        ),
      );
    });

    test(
      'rewind after a completed rewind errors with the repeat guard',
      () async {
        final fake = _FakeStreamFunction([
          _toolTurn([checkpointCall('c1')]),
          _toolTurn([rewindCall('findings', 'c2')]),
          _textTurn('done'),
        ]);
        final h = await harness(fake);
        await h.agent.prompt('start');
        expect(h.controller.lastCompletedRewind, isNotNull);

        final rewind = h.controller.tools.firstWhere(
          (t) => t.name == rewindToolName,
        );
        await expectLater(
          () => rewind.execute({'report': 'again'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Checkpoint already completed'),
            ),
          ),
        );
      },
    );
  });

  group('rewind application', () {
    test('drops post-mark messages, keeps the report verbatim, and preserves '
        'the detour in the session tree', () async {
      const report = 'FINDINGS: the cache is stale; key points: a, b, c.';
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1', 'probe')]),
        _toolTurn([probeCall('/tmp/x', 'c2')]),
        _toolTurn([rewindCall(report, 'c3')]),
        _textTurn('continuing'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('start');

      // In-memory context: checkpoint prefix + report; the detour and the
      // rewind exchange are gone. The final assistant message of the
      // continued run lands after the report.
      final messages = h.agent.state.messages;
      expect(messages, hasLength(5));
      expect(messages[0], isA<UserMessage>());
      expect(messages[1], isA<AssistantMessage>());
      expect(messages[2], isA<ToolResultMessage>());
      final retained = messages[3] as UserMessage;
      expect(retained.role, 'user');
      expect(retained.content, report); // verbatim
      expect(messages[4], isA<AssistantMessage>());

      // The model continued with the pruned context: the last provider
      // call saw the checkpoint prefix plus the report, nothing else.
      final lastCall = fake.contexts.last;
      expect(lastCall.systemPrompt, 'test system prompt');
      expect(lastCall.messages, hasLength(4));
      expect((lastCall.messages.last as UserMessage).content, report);

      // Session: the active branch ends at the checkpoint record +
      // branch_summary (the report) + hidden rewind-report message.
      final session = h.host.session!;
      final branch = await activeBranch(session);
      final checkpoint = branch.whereType<CheckpointRecord>().single;
      final branchSummary = branch.whereType<BranchSummaryRecord>().single;
      expect(branchSummary.summary, report);
      expect(branchSummary.fromId, checkpoint.id);
      final rewindReport = branch.whereType<CustomMessageRecord>().single;
      expect(rewindReport.customType, rewindReportCustomType);
      expect(rewindReport.content, report);
      expect(rewindReport.display, isFalse);
      expect(branch.last, same(rewindReport));

      // The detour (probe exchange + rewind exchange) is preserved on the
      // abandoned branch — nothing is lost.
      final abandoned = await session.getChildren(checkpoint.id);
      final abandonedMessages = abandoned.whereType<MessageRecord>().toList();
      expect(abandonedMessages, isNotEmpty);
      final detour = abandonedMessages.first.message as AssistantMessage;
      expect(detour.content.whereType<ToolCall>().single.name, 'probe');
      final allEntries = await session.getEntries();
      final rewindResult = allEntries
          .whereType<MessageRecord>()
          .map((e) => e.message)
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolName == rewindToolName);
      expect(rewindResult.isError, isFalse);

      // A rebuilt context is coherent: prefix, then the branch summary
      // (wrapped), then the verbatim rewind report.
      final rebuilt = await session.buildContextMessages();
      expect(rebuilt, hasLength(5));
      final summaryMessage = rebuilt[3] as UserMessage;
      expect(
        summaryMessage.content,
        '$branchSummaryPrefix$report$branchSummarySuffix',
      );
      expect((rebuilt[4] as UserMessage).content, report);

      // The host persistence cursor realigned: a host flush persists only
      // the post-rewind message, right after the rewind-report record.
      await h.host.flush(h.agent);
      final afterFlush = await activeBranch(session);
      expect(afterFlush.last, isA<MessageRecord>());
      expect(
        (afterFlush.last as MessageRecord).message,
        isA<AssistantMessage>(),
      );
      expect(afterFlush[afterFlush.length - 2], same(rewindReport));
    });

    test('extends the keep range over dangling tool results', () async {
      const report = 'batched checkpoint findings';
      final fake = _FakeStreamFunction([
        // checkpoint + probe in ONE batch (checkpoint first): the mark lands
        // between the checkpoint result and the probe result.
        _toolTurn([checkpointCall('c1'), probeCall('/a', 'c2')]),
        _toolTurn([rewindCall(report, 'c3')]),
        _textTurn('continuing'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('start');

      final messages = h.agent.state.messages;
      // user + assistant(2 calls) + checkpoint result + probe result +
      // report + final assistant
      expect(messages, hasLength(6));
      expect(messages[3], isA<ToolResultMessage>());
      expect((messages[3] as ToolResultMessage).toolName, 'probe');
      // No dangling tool calls remain in the kept prefix.
      final keptAssistant = messages[1] as AssistantMessage;
      final callIds = keptAssistant.content.whereType<ToolCall>().map(
        (c) => c.id,
      );
      final resultIds = messages.whereType<ToolResultMessage>().map(
        (m) => m.toolCallId,
      );
      expect(resultIds, containsAll(callIds));
      expect((messages[4] as UserMessage).content, report);
    });

    test('works without a session (in-memory pruning only)', () async {
      const report = 'sessionless findings';
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1')]),
        _toolTurn([probeCall('/a', 'c2')]),
        _toolTurn([rewindCall(report, 'c3')]),
        _textTurn('continuing'),
      ]);
      final h = await harness(fake, withSession: false);
      await h.agent.prompt('start');

      final messages = h.agent.state.messages;
      expect(messages, hasLength(5));
      expect((messages[3] as UserMessage).content, report);
      expect(fake.contexts.last.messages, hasLength(4));
    });

    test('checkpoint in one run, rewind in a later run', () async {
      const report = 'cross-run findings';
      final fake = _FakeStreamFunction([
        _toolTurn([checkpointCall('c1', 'span runs')]),
        _textTurn('run one done'),
        _toolTurn([probeCall('/later', 'c2')]),
        _toolTurn([rewindCall(report, 'c3')]),
        _textTurn('run two done'),
      ]);
      final h = await harness(fake);
      await h.agent.prompt('run one');
      await h.host.flush(h.agent); // host batch persistence between runs
      await h.agent.prompt('run two');

      final messages = h.agent.state.messages;
      expect(messages, hasLength(5));
      expect((messages[3] as UserMessage).content, report);
      expect(messages[4], isA<AssistantMessage>());

      final session = h.host.session!;
      final branch = await activeBranch(session);
      expect(branch.whereType<CheckpointRecord>(), hasLength(1));
      expect(branch.whereType<BranchSummaryRecord>().single.summary, report);
      // The run-one tail ("run one done" assistant message) and the run-two
      // detour stayed in the tree on the abandoned branch.
      final allText = (await session.getEntries())
          .whereType<MessageRecord>()
          .map((e) => e.message)
          .whereType<AssistantMessage>()
          .expand((m) => m.content.whereType<TextContent>())
          .map((b) => b.text)
          .join('\n');
      expect(allText, contains('run one done'));

      // Follow-up persistence stays aligned after the rewind: only the
      // post-rewind message lands, at the tip of the new branch.
      await h.host.flush(h.agent);
      final afterFlush = await activeBranch(session);
      expect(afterFlush.last, isA<MessageRecord>());
      expect(
        (afterFlush.last as MessageRecord).message,
        isA<AssistantMessage>(),
      );
    });
  });
}
