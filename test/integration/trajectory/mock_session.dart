/// Deterministic mock session fixtures for the trajectory integration tests.
///
/// `MockSessionScript` describes a session as a flat list of event-builder
/// calls (`user`, `assistantText`, `toolCall`, `toolResult`, `compaction`,
/// `branchSummary`, `checkpoint`, `modelChange`, `contextInject`, and the
/// `turn` convenience). `MockSessionFixture.build` persists the script as a
/// REAL JSONL session through [JsonlSessionRepo] (the production storage
/// path) into a temp sessions root and hands back the repo, the session id,
/// and every appended record.
///
/// Fixtures are fully deterministic: record ids are `rec001`, `rec002`, …,
/// the session id is fixed, and timestamps are monotonic offsets from
/// [mockSessionBase] (each record advances a script-local clock, so
/// durations derived from record stamps are exact).
library;

import 'dart:io';
import 'package:flutter_agent_harness/src/env/io_execution_env.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The fixed instant every fixture timestamp derives from.
final DateTime mockSessionBase = DateTime.utc(2026, 3, 1, 12);

/// One scripted event; the fixture turns it into a [SessionRecord].
abstract base class MockStep {
  /// Clock offset from [mockSessionBase] assigned by the script.
  final Duration offset;

  MockStep(this.offset);

  /// Builds the record with the fixture's [id], leaf-parent [parentId], and
  /// base-shifted [timestamp].
  SessionRecord record(String id, String? parentId, DateTime timestamp);
}

/// `user(text)` — a user message opening (or continuing) a turn.
final class MockUserStep extends MockStep {
  MockUserStep(super.offset, this.text);

  final String text;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      MessageRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        message: UserMessage.text(text, timestamp: timestamp),
      );
}

/// A tool invocation scripted inside an assistant step.
final class MockToolCallSpec {
  const MockToolCallSpec(
    this.callId, {
    this.name = 'bash',
    this.args = const {'cmd': 'ls'},
    this.result = 'ok',
    this.isError = false,
  });

  final String callId;
  final String name;
  final Map<String, Object?> args;
  final String result;
  final bool isError;
}

/// Tool-call blocks of an assistant step (a step may carry several).
typedef MockToolCalls = List<MockToolCallSpec>;

/// `assistantText(text)` — a model response with text and/or tool calls.
final class MockAssistantStep extends MockStep {
  MockAssistantStep(
    super.offset,
    this.text, {
    this.toolCalls = const [],
    this.provider = 'mock',
    this.model = 'mock-model',
    this.usage,
  });

  final String text;
  final MockToolCalls toolCalls;
  final String provider;
  final String model;
  final Usage? usage;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) {
    final blocks = <ContentBlock>[
      if (text.isNotEmpty) TextContent(text: text),
      for (final call in toolCalls)
        ToolCall(id: call.callId, name: call.name, arguments: call.args),
    ];
    return MessageRecord(
      id: id,
      parentId: parentId,
      timestamp: timestamp,
      message: AssistantMessage(
        content: blocks,
        api: 'mock-api',
        provider: provider,
        model: model,
        usage:
            usage ??
            const Usage(
              input: 100,
              output: 20,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 120,
              cost: UsageCost(total: 0.01),
            ),
        stopReason: StopReason.stop,
        timestamp: timestamp,
      ),
    );
  }
}

/// `toolResult(callId, result)` — a settled tool execution.
final class MockToolResultStep extends MockStep {
  MockToolResultStep(super.offset, this.spec);

  final MockToolCallSpec spec;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      MessageRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        message: ToolResultMessage(
          toolCallId: spec.callId,
          toolName: spec.name,
          content: [TextContent(text: spec.result)],
          isError: spec.isError,
          timestamp: timestamp,
        ),
      );
}

/// `compaction(...)` — a compaction point collapsing earlier history.
final class MockCompactionStep extends MockStep {
  MockCompactionStep(
    super.offset, {
    required this.summary,
    required this.firstKeptEntryId,
    this.tokensBefore = 900,
  });

  final String summary;
  final String firstKeptEntryId;
  final int tokensBefore;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      CompactionRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        summary: summary,
        firstKeptEntryId: firstKeptEntryId,
        tokensBefore: tokensBefore,
      );
}

/// `branchSummary(...)` — a branch navigation mark.
final class MockBranchSummaryStep extends MockStep {
  MockBranchSummaryStep(
    super.offset, {
    required this.fromId,
    required this.summary,
  });

  final String fromId;
  final String summary;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      BranchSummaryRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        fromId: fromId,
        summary: summary,
      );
}

/// `checkpoint(...)` — a checkpoint mark for a later rewind.
final class MockCheckpointStep extends MockStep {
  MockCheckpointStep(super.offset, {required this.messageCount, this.goal});

  final int messageCount;
  final String? goal;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      CheckpointRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        messageCount: messageCount,
        goal: goal,
      );
}

/// `modelChange(...)` — an active-model switch row.
final class MockModelChangeStep extends MockStep {
  MockModelChangeStep(
    super.offset, {
    required this.provider,
    required this.modelId,
  });

  final String provider;
  final String modelId;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      ModelChangeRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        provider: provider,
        modelId: modelId,
      );
}

/// `contextInject(text)` — a hidden context message rendered as a CONTEXT row.
final class MockContextInjectStep extends MockStep {
  MockContextInjectStep(super.offset, this.text);

  final String text;

  @override
  SessionRecord record(String id, String? parentId, DateTime timestamp) =>
      CustomMessageRecord(
        id: id,
        parentId: parentId,
        timestamp: timestamp,
        customType: 'context',
        content: text,
        display: true,
      );
}

/// The scripted session description. Builders append steps; the clock only
/// ever moves forward.
final class MockSessionScript {
  final _steps = <MockStep>[];
  Duration _clock = Duration.zero;

  /// The scripted steps in call order.
  List<MockStep> get steps => List.unmodifiable(_steps);

  /// The session-record id the n-th step (1-based) will get — lets tests
  /// wire `firstKeptEntryId`/`fromId` to earlier steps.
  String stepId(int step) => 'rec${step.toString().padLeft(3, '0')}';

  Duration _tick([Duration gap = const Duration(seconds: 1)]) {
    _clock += gap;
    return _clock;
  }

  void _add(MockStep step) => _steps.add(step);

  /// Appends a user message.
  void user(String text) => _add(MockUserStep(_tick(), text));

  /// Appends an assistant response carrying text (and optional tool calls).
  void assistantText(
    String text, {
    MockToolCalls toolCalls = const [],
    String provider = 'mock',
    String model = 'mock-model',
    Usage? usage,
  }) => _add(
    MockAssistantStep(_tick(), text, toolCalls: toolCalls, usage: usage),
  );

  /// Appends a single-call assistant step (`toolCall` builder).
  void toolCall(
    String callId, {
    String name = 'bash',
    Map<String, Object?> args = const {'cmd': 'ls'},
  }) => _add(
    MockAssistantStep(
      _tick(),
      '',
      toolCalls: [MockToolCallSpec(callId, name: name, args: args)],
    ),
  );

  /// Appends a tool result for [callId]; [after] sets the call→result gap
  /// the ledger's tool duration derives from.
  void toolResult(
    String callId,
    String result, {
    Duration after = const Duration(seconds: 3),
    bool isError = false,
  }) => _add(
    MockToolResultStep(
      _tick(after),
      MockToolCallSpec(callId, result: result, isError: isError),
    ),
  );

  /// Appends a compaction point. [firstKeptEntryId] is usually
  /// `stepId(n)` of an earlier step.
  void compaction({
    required String summary,
    required String firstKeptEntryId,
    int tokensBefore = 900,
  }) => _add(
    MockCompactionStep(
      _tick(),
      summary: summary,
      firstKeptEntryId: firstKeptEntryId,
      tokensBefore: tokensBefore,
    ),
  );

  /// Appends a branch-summary mark pointing back at [fromId].
  void branchSummary({required String fromId, required String summary}) =>
      _add(MockBranchSummaryStep(_tick(), fromId: fromId, summary: summary));

  /// Appends a checkpoint mark.
  void checkpoint({required int messageCount, String? goal}) =>
      _add(MockCheckpointStep(_tick(), messageCount: messageCount, goal: goal));

  /// Appends a model-change row.
  void modelChange({required String provider, required String modelId}) =>
      _add(MockModelChangeStep(_tick(), provider: provider, modelId: modelId));

  /// Appends a hidden context message (a CONTEXT ledger row).
  void contextInject(String text) => _add(MockContextInjectStep(_tick(), text));

  /// Appends a full turn in one call: the user prompt, then (when
  /// [toolCalls] is non-empty) one assistant step carrying every call, then
  /// one result per call spaced [perToolLatency] apart.
  void turn(
    String userText, {
    MockToolCalls toolCalls = const [],
    Duration perToolLatency = const Duration(seconds: 2),
  }) {
    user(userText);
    if (toolCalls.isEmpty) return;
    assistantText('', toolCalls: toolCalls);
    for (final call in toolCalls) {
      _add(MockToolResultStep(_tick(perToolLatency), call));
    }
  }
}

/// A scripted session persisted through the real [JsonlSessionRepo] into a
/// temp sessions root.
final class MockSessionFixture {
  MockSessionFixture({
    required this.repo,
    required this.session,
    required this.sessionId,
    required this.records,
  });

  /// The repository over the temp sessions root.
  final JsonlSessionRepo repo;

  /// The still-open session (use for `moveTo` branch scenarios).
  final Session session;

  /// The fixed session id the fixture created.
  final String sessionId;

  /// Every appended record, in file order.
  final List<SessionRecord> records;

  static var _seq = 0;

  /// Persists [script] as a real JSONL session under [sessionsRoot].
  static Future<MockSessionFixture> build(
    MockSessionScript script, {
    required Directory sessionsRoot,
  }) async {
    final repo = JsonlSessionRepo(
      fs: LocalFileSystem(cwd: sessionsRoot.path),
      sessionsRoot: sessionsRoot.path,
    );
    final sessionId = 'mock-sess-${++_seq}-fixed';
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', id: sessionId),
    );
    final storage = session.getStorage();
    String? parentId;
    final appended = <SessionRecord>[];
    var step = 0;
    for (final stepDef in script.steps) {
      final record = stepDef.record(
        script.stepId(++step),
        parentId,
        mockSessionBase.add(stepDef.offset),
      );
      await storage.appendEntry(record);
      parentId = record.id;
      appended.add(record);
    }
    return MockSessionFixture(
      repo: repo,
      session: session,
      sessionId: sessionId,
      records: appended,
    );
  }

  /// Re-opens the session through the repo and returns the active branch —
  /// the full JSONL disk round trip the builder consumes.
  Future<List<SessionRecord>> readBack() async {
    final metadata = (await repo.list()).firstWhere(
      (metadata) => metadata.id == sessionId,
    );
    return (await repo.open(metadata)).getBranch();
  }

  /// Appends one more record at the current leaf (branch continuation).
  Future<SessionRecord> append(SessionRecord record) async {
    await session.getStorage().appendEntry(record);
    return record;
  }
}
