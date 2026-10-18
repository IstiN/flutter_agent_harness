/// ATIF (Agent Trajectory Interchange Format) export of a trajectory
/// snapshot (gh-1681 Gap 2).
///
/// Harbor's leaderboard pipeline requires every rewarded trial to carry an
/// ATIF trajectory at `<trial>/agent/trajectory.json` — the harbor upload
/// packager stores it as the trial's `trajectory_path` and the static
/// analysis rejects trials without one. Harbor does NOT convert installed
/// agents' logs itself: every shipped adapter writes its own
/// `trajectory.json`, so the fa adapter (`bench/harbor_fa/fa_agent.py`)
/// invokes `fa trajectory export --format atif` after the agent phase and
/// this module is the format behind it.
///
/// Schema contract: ATIF-v1.7 (the version harbor 0.23.0's claude-code
/// adapter emits), pinned against `harbor/models/trajectories/*.py` and
/// cross-validated from Python by `bench/harbor_fa/test_atif_contract.py`
/// against the same golden fixture the Dart test reads
/// (`bench/harbor_fa/fixtures/atif_sample.json`). Pure function: no IO.
library;

import 'dart:convert';

import 'trajectory_record.dart';
import 'trajectory_snapshot.dart';

/// Serializes [snapshot] as an ATIF-v1.7 JSON document, or null when the
/// ledger projects no steps (ATIF requires at least one — a rewarded trial
/// always has steps, so an empty export means nothing worth submitting).
///
/// Mapping: user records become `source: "user"` steps; context, compacted
/// and system records become `source: "system"` steps (the harness
/// originating them); assistant records become `source: "agent"` steps
/// with the message, reasoning content and per-step token metrics; tool
/// records become deterministic-dispatch agent steps (`llm_call_count: 0`)
/// carrying the structured call and its observation. Tool-call arguments
/// parse from the raw JSON payload; an unparseable payload exports empty
/// arguments with the raw text preserved on the call's `extra` — the
/// ATIF field types are never violated.
String? exportAtifJson(
  TrajectorySnapshot snapshot, {
  required String agentName,
  required String agentVersion,
  String? sessionId,
  String? modelName,
  String? notes,
}) {
  final steps = <Map<String, dynamic>>[
    for (final record in snapshot.records) _atifStep(record),
  ];
  if (steps.isEmpty) return null;
  final model = modelName ?? _derivedModel(snapshot);
  return const JsonEncoder.withIndent('  ').convert({
    'schema_version': 'ATIF-v1.7',
    if (sessionId != null) 'session_id': sessionId,
    'agent': {
      'name': agentName,
      'version': agentVersion,
      if (model != null) 'model_name': model,
    },
    'steps': steps,
    if (notes != null) 'notes': notes,
    'final_metrics': _finalMetrics(steps),
  });
}

/// The first assistant-reported model, when any — the run's effective
/// model for trajectories that never saw a `modelName` override.
String? _derivedModel(TrajectorySnapshot snapshot) {
  for (final record in snapshot.records) {
    if (record is TrajectoryAssistantRecord && record.model != null) {
      return record.model;
    }
  }
  return null;
}

Map<String, dynamic> _atifStep(TrajectoryRecord record) => switch (record) {
  TrajectoryUserRecord() => _step(
    record,
    'user',
    timestamp: record.startedAt,
    message: record.text,
  ),
  TrajectoryContextRecord() => _step(
    record,
    'system',
    timestamp: record.startedAt,
    message: record.text,
  ),
  TrajectoryCompactedRecord() => _step(
    record,
    'system',
    timestamp: record.startedAt,
    message: record.summary,
  ),
  TrajectorySystemRecord() => _step(
    record,
    'system',
    timestamp: record.time,
    message: record.text,
  ),
  TrajectoryAssistantRecord() => _assistantStep(record),
  TrajectoryToolRecord() => _toolStep(record),
};

Map<String, dynamic> _step(
  TrajectoryRecord record,
  String source, {
  required String message,
  DateTime? timestamp,
}) => {
  'step_id': record.index,
  if (timestamp != null) 'timestamp': timestamp.toIso8601String(),
  'source': source,
  'message': message,
};

Map<String, dynamic> _assistantStep(TrajectoryAssistantRecord record) {
  final metrics = _metrics(record);
  return {
    'step_id': record.index,
    if (record.stepStartTime ?? record.completedTime
        case final time?) ...{
      'timestamp': time.toIso8601String(),
    },
    'source': 'agent',
    if (record.model != null) 'model_name': record.model,
    'message': _assistantMessage(record),
    if (record.thinkingDetail != null && record.thinkingDetail!.isNotEmpty)
      'reasoning_content': record.thinkingDetail,
    if (metrics != null) 'metrics': metrics,
  };
}

/// The assistant's text: the finalized output blocks in order, falling
/// back to the row's display label when the message carried no text.
String _assistantMessage(TrajectoryAssistantRecord record) {
  final text = record.outputBlocks
      .where((block) => block.type == 'text')
      .map((block) => block.content)
      .join('\n')
      .trim();
  return text.isNotEmpty ? text : record.displayText;
}

Map<String, dynamic>? _metrics(TrajectoryAssistantRecord record) {
  final prompt = record.inputTokens ?? record.usage?.input;
  final completion = record.outputTokens ?? record.usage?.output;
  final cached = record.cacheReadTokens ?? record.usage?.cacheRead;
  final cost = record.usage?.cost.total ?? 0;
  if (prompt == null && completion == null && cached == null && cost <= 0) {
    return null;
  }
  return {
    if (prompt != null) 'prompt_tokens': prompt,
    if (completion != null) 'completion_tokens': completion,
    if (cached != null) 'cached_tokens': cached,
    if (cost > 0) 'cost_usd': cost,
  };
}

Map<String, dynamic> _toolStep(TrajectoryToolRecord record) {
  final arguments = _toolArguments(record.argsRaw);
  final result = record.result;
  return {
    'step_id': record.index,
    if (record.startedAt != null)
      'timestamp': record.startedAt!.toIso8601String(),
    'source': 'agent',
    'llm_call_count': 0,
    'tool_calls': [
      {
        'tool_call_id': record.callId,
        'function_name': record.name,
        'arguments': arguments.$1,
        if (arguments.$2 != null) 'extra': {'raw_arguments': arguments.$2},
      },
    ],
    // A call whose result never arrived (killed mid-flight) exports no
    // observation rather than an empty one.
    if (result.isNotEmpty)
      'observation': {
        'results': [
          {'source_call_id': record.callId, 'content': result},
        ],
      },
  };
}

/// Parses the raw JSON tool arguments into the ATIF `(arguments, raw)`
/// pair: a decoded map, or an empty map with the raw payload preserved on
/// `extra` when the payload is not a JSON object.
(Map<String, dynamic>, String?) _toolArguments(String argsRaw) {
  try {
    final decoded = jsonDecode(argsRaw);
    if (decoded is Map<String, dynamic>) return (decoded, null);
  } on Object {
    // Not JSON at all — the raw fallback below covers it.
  }
  return (<String, dynamic>{}, argsRaw);
}

Map<String, dynamic> _finalMetrics(List<Map<String, dynamic>> steps) {
  var prompt = 0, completion = 0, cached = 0;
  double cost = 0;
  for (final step in steps) {
    final metrics = step['metrics'];
    if (metrics is! Map<String, dynamic>) continue;
    prompt += (metrics['prompt_tokens'] as int?) ?? 0;
    completion += (metrics['completion_tokens'] as int?) ?? 0;
    cached += (metrics['cached_tokens'] as int?) ?? 0;
    cost += (metrics['cost_usd'] as num?)?.toDouble() ?? 0;
  }
  return {
    'total_prompt_tokens': prompt,
    'total_completion_tokens': completion,
    'total_cached_tokens': cached,
    if (cost > 0) 'total_cost_usd': cost,
    'total_steps': steps.length,
  };
}
