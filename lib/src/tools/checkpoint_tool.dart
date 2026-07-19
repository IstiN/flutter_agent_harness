/// The `checkpoint`/`rewind` tools: self-service context hygiene for
/// exploratory detours, plus the controller that applies the rewind to the
/// live agent and the session tree.
///
/// Ported from oh-my-pi (`packages/coding-agent/src/tools/checkpoint.ts` +
/// `docs/tools/checkpoint.md` + `docs/tools/rewind.md`). The model marks the
/// conversation with `checkpoint(goal)`, investigates with intermediate tool
/// calls, then calls `rewind(report)`: everything after the mark is pruned
/// from the live context and replaced by the report (kept verbatim), while
/// the dropped history stays in the session tree as an abandoned branch —
/// nothing is lost.
///
/// omp splits the flow between dumb tools and an `AgentSession` that captures
/// state on `tool_execution_end` and applies the rewind on `turn_end`; here
/// the [CheckpointRewindController] plays the session role: it subscribes to
/// agent events (capture on the checkpoint tool-result message, apply on
/// turn end) and wraps [Agent.prepareNextTurn] so the ongoing run continues
/// with the pruned context. omp's subagent gate does not exist (no subagent
/// sessions yet), and omp's yield guard is not ported.
///
/// Persistence model: hosts persist in-memory messages to the session on
/// their own schedule (the CLI batches at run end). The controller therefore
/// drives persistence of everything it anchors or drops through the
/// [CheckpointSessionSink] — the checkpoint prefix at capture time and the
/// whole detour at rewind time — so the tree always mirrors the anchors.
library;

// The public named parameters map to private fields; initializing formals
// would make the parameter names private and unusable outside this library.
// ignore_for_file: prefer_initializing_formals

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../prompts/prompts.g.dart';
import '../session/session_tree.dart';
import '../types.dart';

/// The `checkpoint` tool name.
const checkpointToolName = 'checkpoint';

/// The `rewind` tool name.
const rewindToolName = 'rewind';

/// The `custom_message` type carrying the retained rewind report in the
/// session tree (omp's `rewind-report` custom message).
const rewindReportCustomType = 'rewind-report';

/// The captured checkpoint mark (omp's `CheckpointState`).
final class CheckpointState {
  /// Creates a [CheckpointState].
  const CheckpointState({
    required this.messageCount,
    required this.startedAt,
    this.entryId,
    this.goal,
  });

  /// In-memory message count at the mark, AFTER the checkpoint tool result
  /// was appended (omp semantics). The rewind prunes back to this count.
  final int messageCount;

  /// Session-tree anchor: the [CheckpointRecord] id written at the mark, or
  /// `null` when the host has no session. The rewind navigates the tree back
  /// to this record.
  final String? entryId;

  /// When the checkpoint was created.
  final DateTime startedAt;

  /// Optional investigation goal given by the model.
  final String? goal;
}

/// A completed rewind retained for the repeat-call guard (omp's
/// `CompletedRewindState`).
final class CompletedRewind {
  /// Creates a [CompletedRewind].
  const CompletedRewind({
    required this.report,
    required this.startedAt,
    required this.rewoundAt,
  });

  /// The report retained after the rewind, verbatim.
  final String report;

  /// When the rewound checkpoint was created.
  final DateTime startedAt;

  /// When the rewind completed.
  final DateTime rewoundAt;
}

/// The host seam for session persistence the controller drives.
///
/// Hosts persist the in-memory transcript on their own schedule; the
/// controller needs precise anchors, so it flushes the messages it relies on
/// through [persistMessage] itself (idempotent for hosts that persist live —
/// [persistedMessageCount] then already covers them).
final class CheckpointSessionSink {
  /// Creates a [CheckpointSessionSink].
  const CheckpointSessionSink({
    required this.session,
    required this.persistedMessageCount,
    required this.persistMessage,
  });

  /// The current session, or `null` when the host has none (the controller
  /// then degrades to in-memory pruning only).
  final Session? Function() session;

  /// How many leading in-memory messages the host has already persisted.
  final int Function() persistedMessageCount;

  /// Persists one in-memory [message] at the session leaf and bumps the
  /// host's persisted counter. Returns the new record id.
  final Future<String> Function(Message message) persistMessage;
}

/// Orchestrates the `checkpoint`/`rewind` flow for one [Agent].
///
/// Created once per agent (the CLI creates one next to [builtinTools]); the
/// [tools] register next to the other built-ins. Capture and application
/// ride the agent's event stream, so the tools themselves stay simple.
final class CheckpointRewindController {
  /// Creates a controller and attaches it to [agent]: subscribes to the
  /// event stream and wraps [Agent.prepareNextTurn] (preserving any existing
  /// hook, the same composition pattern `attachApproval` uses).
  ///
  /// [onRewindApplied] fires after each applied rewind with the new
  /// in-memory message count, so the host can realign its persistence cursor
  /// (the pruned detour and the report are already persisted by then).
  CheckpointRewindController({
    required Agent agent,
    required CheckpointSessionSink sink,
    void Function(int messageCount)? onRewindApplied,
  }) : _agent = agent,
       _sink = sink,
       _onRewindApplied = onRewindApplied {
    _unsubscribe = _agent.subscribe(_onAgentEvent);
    _wrapPrepareNextTurn();
  }

  final Agent _agent;
  final CheckpointSessionSink _sink;
  final void Function(int messageCount)? _onRewindApplied;

  CheckpointState? _active;
  CompletedRewind? _lastCompleted;
  bool _checkpointPending = false;
  String? _pendingGoal;
  String? _pendingReport;
  bool _contextSwapPending = false;
  PrepareNextTurnHook? _previousPrepareNextTurn;
  PrepareNextTurnHook? _wrappedPrepareNextTurn;
  void Function()? _unsubscribe;

  /// The `checkpoint` and `rewind` tools bound to this controller.
  late final List<AgentTool> tools = [
    _buildCheckpointTool(),
    _buildRewindTool(),
  ];

  /// The active checkpoint, if any.
  CheckpointState? get activeCheckpoint => _active;

  /// The last completed rewind, if any (drives the repeat-call guard).
  CompletedRewind? get lastCompletedRewind => _lastCompleted;

  /// Clears all checkpoint/rewind state (e.g. when the host resets the
  /// session).
  void clear() {
    _active = null;
    _lastCompleted = null;
    _checkpointPending = false;
    _pendingGoal = null;
    _pendingReport = null;
    _contextSwapPending = false;
  }

  /// Detaches from the agent: unsubscribes the event listener and restores
  /// the [Agent.prepareNextTurn] hook this controller wrapped.
  void dispose() {
    _unsubscribe?.call();
    _unsubscribe = null;
    if (identical(_agent.prepareNextTurn, _wrappedPrepareNextTurn)) {
      _agent.prepareNextTurn = _previousPrepareNextTurn;
    }
  }

  void _wrapPrepareNextTurn() {
    _previousPrepareNextTurn = _agent.prepareNextTurn;
    final previous = _previousPrepareNextTurn;
    _wrappedPrepareNextTurn = (nextTurn) async {
      if (_contextSwapPending) {
        _contextSwapPending = false;
        // The rewind pruned the transcript; the loop's context still holds
        // the dropped messages, so swap in the pruned one — the model
        // continues with the checkpoint prefix plus the retained report.
        return AgentLoopTurnUpdate(
          context: Context(
            systemPrompt: nextTurn.context.systemPrompt,
            messages: _agent.state.messages,
            tools: nextTurn.context.tools,
          ),
        );
      }
      return previous?.call(nextTurn);
    };
    _agent.prepareNextTurn = _wrappedPrepareNextTurn;
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    switch (event) {
      case MessageEndEvent(:final message):
        // The checkpoint mark is captured once its tool result is part of
        // the transcript, so the count matches omp's "after the checkpoint
        // tool result has already been appended".
        if (message is ToolResultMessage &&
            message.toolName == checkpointToolName) {
          await _captureCheckpoint(message);
        }
      case TurnEndEvent():
        // omp applies the rewind on turn_end, never inside the tool call.
        if (_pendingReport != null) await _applyRewind();
      default:
    }
  }

  Future<void> _captureCheckpoint(ToolResultMessage result) async {
    if (!_checkpointPending) return;
    _checkpointPending = false;
    final goal = _pendingGoal;
    _pendingGoal = null;
    if (result.isError) return;

    final messages = _agent.state.messages;
    final count = messages.length;
    final session = _sink.session();
    String? entryId;
    if (session != null) {
      // Flush the host-pending prefix (the prompt and the checkpoint
      // exchange) so the tree anchor and the in-memory anchor point at the
      // same conversation position, then mark it with a checkpoint record.
      for (var i = _sink.persistedMessageCount(); i < count; i++) {
        await _sink.persistMessage(messages[i]);
      }
      entryId = await session.appendCheckpoint(messageCount: count, goal: goal);
    }
    _active = CheckpointState(
      messageCount: count,
      entryId: entryId,
      startedAt: DateTime.now(),
      goal: goal,
    );
  }

  Future<void> _applyRewind() async {
    final checkpoint = _active;
    final report = _pendingReport;
    _pendingReport = null;
    if (checkpoint == null || report == null) return;
    final rewoundAt = DateTime.now();

    final messages = _agent.state.messages;
    final keepCount = _resolveDanglingToolCalls(
      messages,
      checkpoint.messageCount.clamp(0, messages.length),
    );

    final session = _sink.session();
    if (session != null) {
      // Persist the whole detour BEFORE moving the leaf: the dropped history
      // stays in the tree as an abandoned branch (omp semantics — rewind is
      // not destructive to persisted session history).
      for (var i = _sink.persistedMessageCount(); i < messages.length; i++) {
        await _sink.persistMessage(messages[i]);
      }
      final anchor = checkpoint.entryId;
      final targetId = anchor != null && await session.getEntry(anchor) != null
          ? anchor
          : null;
      // Branch back to the checkpoint record, carrying the report as the
      // branch summary (omp's `branchWithSummary`), then retain the report
      // verbatim as a hidden rewind-report message on the new branch.
      await session.moveTo(targetId, summary: report);
      await session.appendCustomMessageEntry(
        customType: rewindReportCustomType,
        content: report,
        display: false,
        details: {
          'startedAt': checkpoint.startedAt.toIso8601String(),
          'rewoundAt': rewoundAt.toIso8601String(),
        },
      );
    }

    _agent.state.messages = [
      ...messages.sublist(0, keepCount),
      UserMessage.text(report),
    ];
    _onRewindApplied?.call(_agent.state.messages.length);
    _active = null;
    _lastCompleted = CompletedRewind(
      report: report,
      startedAt: checkpoint.startedAt,
      rewoundAt: rewoundAt,
    );
    _contextSwapPending = true;
  }

  /// Extends [keepCount] past any tool results still answering tool calls
  /// inside the kept prefix, so a checkpoint batched with other calls never
  /// leaves a dangling tool call in the pruned context.
  static int _resolveDanglingToolCalls(List<Message> messages, int keepCount) {
    var end = keepCount;
    while (end < messages.length) {
      final called = <String>{};
      final answered = <String>{};
      for (var i = 0; i < end; i++) {
        final message = messages[i];
        if (message is AssistantMessage) {
          for (final call in message.content.whereType<ToolCall>()) {
            called.add(call.id);
          }
        } else if (message is ToolResultMessage) {
          answered.add(message.toolCallId);
        }
      }
      if (called.difference(answered).isEmpty) return end;
      end++;
    }
    return end;
  }

  AgentTool _buildCheckpointTool() {
    return AgentTool(
      name: checkpointToolName,
      label: 'checkpoint',
      tier: ApprovalTier.read,
      // Sequential batches make the capture deterministic when the model
      // batches checkpoint with other calls (omp effectively assumes
      // standalone calls).
      executionMode: ToolExecutionMode.sequential,
      description: checkpointToolDescriptionPrompt,
      parameters: const {
        'type': 'object',
        'properties': {
          'goal': {
            'type': 'string',
            'description': 'Investigation goal for this checkpoint',
          },
        },
      },
      execute: (arguments, cancelToken, onUpdate) async {
        if (_active != null) {
          throw StateError(
            'Checkpoint already active. Call rewind with your investigation '
            'findings before creating another checkpoint.',
          );
        }
        _checkpointPending = true;
        final goal = (arguments['goal'] as String?)?.trim();
        _pendingGoal = goal == null || goal.isEmpty ? null : goal;
        // The exact count is captured when the checkpoint tool result lands
        // in the transcript; this prediction matches it for standalone calls.
        final count = _agent.state.messages.length + 1;
        return ToolExecutionResult.text(
          [
            'Checkpoint created (message count: $count).',
            if (_pendingGoal != null) 'Goal: $_pendingGoal',
            'Run your investigation, then call rewind with a concise report.',
          ].join('\n'),
        );
      },
    );
  }

  AgentTool _buildRewindTool() {
    return AgentTool(
      name: rewindToolName,
      label: 'rewind',
      tier: ApprovalTier.read,
      executionMode: ToolExecutionMode.sequential,
      description: rewindToolDescriptionPrompt,
      parameters: const {
        'type': 'object',
        'properties': {
          'report': {
            'type': 'string',
            'description': 'Investigation findings retained after the rewind',
          },
        },
        'required': ['report'],
      },
      execute: (arguments, cancelToken, onUpdate) async {
        if (_active == null) {
          if (_lastCompleted != null) {
            throw StateError(
              'Checkpoint already completed; continue from the retained '
              'rewind report instead of calling rewind again.',
            );
          }
          throw StateError(
            'No active checkpoint. Create a checkpoint before calling rewind.',
          );
        }
        if (_pendingReport != null) {
          throw StateError(
            'Rewind already requested; it applies when the turn ends.',
          );
        }
        final report = (arguments['report'] as String).trim();
        if (report.isEmpty) {
          throw StateError('Report cannot be empty.');
        }
        _pendingReport = report;
        return ToolExecutionResult.text(
          'Rewind requested.\nReport captured for context replacement.',
        );
      },
    );
  }
}
