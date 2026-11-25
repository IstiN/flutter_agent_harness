// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 (AC2, review round 1): a projection-replacing host
/// transition drops the request snapshot (S0). `Agent.reset()` is the
/// seam every host lands on for a session switch, `/handoff` and a fresh
/// app session; the checkpoint rewind and the over-window relief drop it
/// at their own sites (pinned by their suites).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show RecordSeqIndex;
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'openai-completions',
  provider: 'p',
  baseUrl: 'http://localhost/1',
  contextWindow: 800,
  maxTokens: 512,
);

RequestSnapshot _s0() => RequestSnapshot(
  model: _model,
  messages: const [],
  systemPrompt: '',
  tools: const [],
  seqMap: TranscriptSeqMap(headSeqs: const [], index: RecordSeqIndex(const [])),
  sentAt: DateTime.utc(2026),
);

Never _noRequest(Model _, Context _, {CancelToken? cancelToken}) =>
    throw StateError('no provider request in this test');

Future<ToolExecutionResult> _unusedExecutor(_, _, _) async =>
    ToolExecutionResult.text('unused');

void main() {
  test('AC2: Agent.reset() drops S0 — the projection it described is gone', () {
    final agent = Agent(
      model: _model,
      streamFunction: _noRequest,
      toolExecutor: _unusedExecutor,
    );
    agent.requestSnapshots.capture(_s0());
    expect(agent.requestSnapshots.validFor(_model), isNotNull);

    agent.reset();

    expect(agent.requestSnapshots.validFor(_model), isNull);
    expect(agent.requestSnapshots.invalidReason, 'agent reset');
  });

  test('a reset without a snapshot is a no-op (no spurious reason)', () {
    final agent = Agent(
      model: _model,
      streamFunction: _noRequest,
      toolExecutor: _unusedExecutor,
    );
    agent.reset();
    expect(agent.requestSnapshots.current, isNull);
    expect(agent.requestSnapshots.invalidReason, isNull);
  });
}
