/// The immutable trajectory read model handed to renderers.
///
/// Ported from deepseek-harness `packages/client/ui-trajectory/src/client/
/// trajectory-contract.ts` (`TrajectorySnapshot`) and the `RequestView` /
/// `RunningToolCall` / `PartialAssistant` essentials used by it. Later phases
/// (event projection, layout, timeline, search) read only this snapshot.
library;

import 'dart:collection';

import '../types.dart';

import 'trajectory_record.dart';

/// What a captured provider request was issued for.
enum TrajectoryRequestPurpose { assistant, compaction }

/// Lifecycle state of a captured provider request.
enum TrajectoryRequestStatus { running, completed, failed }

/// Request-header facts retained by the trajectory ledger.
///
/// Port of the TS `RequestView` essentials: sequence, turn/step placement,
/// purpose, provider/model, lifecycle, and usage roll-ups.
final class TrajectoryRequestNumber {
  /// Creates a [TrajectoryRequestNumber].
  const TrajectoryRequestNumber({
    required this.seq,
    required this.turn,
    required this.step,
    required this.purpose,
    required this.provider,
    required this.model,
    required this.status,
    this.startedAt,
    this.completedAt,
    this.usage,
    this.cumulativeUsage,
  });

  /// 1-based operation sequence number.
  final int seq;

  /// Model turn the request belongs to.
  final int turn;

  /// Assistant step within [turn].
  final int step;

  /// Whether this was a model step or a compaction request.
  final TrajectoryRequestPurpose purpose;

  /// Provider id.
  final String provider;

  /// Model id.
  final String model;

  /// Lifecycle state of the request.
  final TrajectoryRequestStatus status;

  /// Wall-clock time the request was issued.
  final DateTime? startedAt;

  /// Wall-clock time the request completed.
  final DateTime? completedAt;

  /// Usage reported by this request.
  final Usage? usage;

  /// Usage accumulated across all completed requests so far.
  final Usage? cumulativeUsage;
}

/// A tool call observed but not yet answered.
final class TrajectoryRunningToolCall {
  /// Creates a [TrajectoryRunningToolCall].
  const TrajectoryRunningToolCall({
    required this.callId,
    required this.name,
    required this.turn,
    required this.step,
    this.startedAt,
  });

  /// Provider-assigned tool call id.
  final String callId;

  /// Invoked tool name.
  final String name;

  /// Model turn the call belongs to.
  final int turn;

  /// Assistant step within [turn].
  final int step;

  /// Wall-clock time the call started.
  final DateTime? startedAt;
}

/// An assistant message that is still streaming.
final class TrajectoryPartialAssistant {
  /// Creates a [TrajectoryPartialAssistant].
  const TrajectoryPartialAssistant({
    required this.messageId,
    required this.turn,
    required this.step,
    required this.blocks,
    this.startedAt,
  });

  /// Session record id (or streaming id) of the partial message.
  final String messageId;

  /// Model turn the partial message belongs to.
  final int turn;

  /// Assistant step within [turn].
  final int step;

  /// Accumulated in-flight blocks so far.
  final List<TrajectoryPartialBlock> blocks;

  /// Wall-clock time the message started streaming.
  final DateTime? startedAt;
}

/// Immutable stage-oriented trajectory data assembled from session records.
final class TrajectorySnapshot {
  /// Creates a [TrajectorySnapshot].
  const TrajectorySnapshot({
    required this.records,
    required this.requests,
    required this.callSchemas,
    required this.partial,
    required this.runningCalls,
    required this.recordLocations,
    required this.revision,
  });

  /// Empty snapshot with [revision] `0`, used before any record is appended.
  static final TrajectorySnapshot empty = TrajectorySnapshot(
    records: UnmodifiableListView(const []),
    requests: UnmodifiableListView(const []),
    callSchemas: const {},
    partial: null,
    runningCalls: UnmodifiableListView(const []),
    recordLocations: const {},
    revision: 0,
  );

  /// Ledger rows in append order.
  final UnmodifiableListView<TrajectoryRecord> records;

  /// Captured provider requests, in issue order.
  final UnmodifiableListView<TrajectoryRequestNumber> requests;

  /// Call-time model-visible tool schema per tool name.
  final Map<String, String> callSchemas;

  /// The assistant message currently streaming, if any.
  final TrajectoryPartialAssistant? partial;

  /// Tool calls issued but not yet answered.
  final UnmodifiableListView<TrajectoryRunningToolCall> runningCalls;

  /// Map of record id to its index in [records].
  final Map<String, int> recordLocations;

  /// Monotonic version of this snapshot; grows by one per builder append.
  final int revision;
}
