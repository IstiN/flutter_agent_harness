import 'dart:collection';

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Shared details-sheet fixture: rich [TrajectoryRecord]s built directly
/// (the core projection leaves the detail fields to hosts) plus a captured
/// [TrajectoryRequestNumber] view.
///
/// Fixture clock: `_base` + seconds; the rich assistant runs 0.3 s to first
/// token and completes at 2.5 s, giving generation 2.2 s and throughput
/// 50 / 2.2 = 22.7 tok/s.

final _base = DateTime.utc(2026, 1, 1, 12);

DateTime _at(int milliseconds) =>
    _base.add(Duration(milliseconds: milliseconds));

const _usage = Usage(
  input: 100,
  output: 50,
  cacheRead: 40,
  cacheWrite: 10,
  reasoning: 20,
  totalTokens: 200,
  cost: UsageCost(),
);

const _blockText = TrajectorySourceBlock(
  type: 'text',
  content: 'Deploying now',
);
const _blockThinking = TrajectorySourceBlock(
  type: 'thinking',
  content: 'Let me think',
);
const _blockCall = TrajectorySourceBlock(
  type: 'toolCall',
  content: '',
  callId: 'call1',
  toolName: 'bash',
);

/// Assistant message with thinking + text + usage + full timing + a prompt
/// pair (drives the Diff tab).
final richAssistant = TrajectoryAssistantRecord(
  index: 1,
  recordId: 'details/assistant',
  messageId: 'm1',
  turn: 1,
  step: 1,
  provider: 'anthropic',
  model: 'claude-test',
  usage: _usage,
  stepStartTime: _at(0),
  firstTokenTime: _at(300),
  completedTime: _at(2500),
  sourceBlocks: const [_blockText, _blockThinking, _blockCall],
  outputBlocks: const [_blockText],
  thinkingDetail: 'Let me think',
  outputDetail: '## Deploy plan\n\nAll good',
  promptDetail: 'line1\nline2\nline3\nline4\nline5\nold tail',
  previousPromptDetail: 'line1\nline2\nline3\nline4\nline5\nline6',
  timeSeconds: const Duration(milliseconds: 2500),
  isError: false,
  requestDetail: const TrajectoryRequestDetail(
    messageCount: 3,
    systemPromptChars: 40,
    toolCount: 1,
    toolNames: ['bash'],
    messages: [
      TrajectoryRequestMessageSummary(
        role: 'user',
        chars: 42,
        preview: 'Run the deployment',
      ),
      TrajectoryRequestMessageSummary(
        role: 'assistant',
        chars: 15,
        preview: 'Deploying now',
      ),
      TrajectoryRequestMessageSummary(
        role: 'toolResult',
        chars: 8,
        preview: 'deployed',
      ),
    ],
  ),
);

/// Assistant without any output detail — Preview shows the empty state.
final emptyAssistant = TrajectoryAssistantRecord(
  index: 2,
  recordId: 'details/assistant-empty',
  messageId: 'm2',
  turn: 1,
  step: 2,
  isError: false,
);

/// Tool call with args, result, and duration.
final settledTool = TrajectoryToolRecord(
  index: 3,
  recordId: 'details/tool',
  callId: 'call1',
  parentCallId: null,
  name: 'bash',
  argsRaw: '{"cmd":"deploy"}',
  result: 'deployed',
  timeSeconds: const Duration(milliseconds: 1200),
  startedAt: _at(2500),
);

/// Failed tool call — Result tab shows the error, Summary the failure.
final failedTool = TrajectoryToolRecord(
  index: 4,
  recordId: 'details/tool-error',
  callId: 'call2',
  parentCallId: null,
  name: 'bash',
  argsRaw: '{}',
  result: 'boom',
  isError: true,
  startedAt: _at(2500),
);

/// Running tool call — no Result tab, Pending status.
final runningTool = TrajectoryToolRecord(
  index: 5,
  recordId: 'details/tool-running',
  callId: 'call3',
  parentCallId: null,
  name: 'bash',
  argsRaw: '{}',
);

/// Initial system prompt with its detail snapshot.
final systemPrompt = TrajectorySystemRecord(
  index: 6,
  recordId: 'details/system',
  text: 'Initial System Prompt',
  change: TrajectorySystemChange.initial,
  detail: 'You are a helpful agent.',
  time: _at(0),
);

/// Compaction summary row.
final compacted = TrajectoryCompactedRecord(
  index: 7,
  recordId: 'details/compacted',
  text: 'summary preview',
  summary: 'Full compaction summary.',
  timeSeconds: const Duration(milliseconds: 800),
  startedAt: _at(4000),
);

/// User prompt with full request detail.
final userPrompt = TrajectoryUserRecord(
  index: 8,
  recordId: 'details/user',
  text: 'Run the deployment',
  previewMarkdown: 'Run the deployment',
  inputDetail: 'Run the deployment\n\n*carefully*',
  opensTurn: true,
);

const _requestUsage = Usage(
  input: 10,
  output: 5,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 15,
  cost: UsageCost(),
);

/// Captured provider request for turn 1 step 1 (the rich assistant), with
/// session cumulative.
final request = TrajectoryRequestNumber(
  seq: 3,
  turn: 1,
  step: 1,
  purpose: TrajectoryRequestPurpose.assistant,
  provider: 'anthropic',
  model: 'claude-test',
  status: TrajectoryRequestStatus.completed,
  startedAt: _at(3000),
  completedAt: _at(3500),
  usage: _requestUsage,
  cumulativeUsage: _usage,
);

/// Snapshot carrying [richAssistant] (for hierarchy lookup) and the bash
/// call schema (drives the Schema tab).
final snapshot = TrajectorySnapshot(
  records: UnmodifiableListView<TrajectoryRecord>([
    richAssistant,
    TrajectoryAssistantRecord(
      index: 2,
      recordId: 'details/assistant-empty',
      messageId: 'm2',
      turn: 1,
      step: 2,
      isError: false,
    ),
  ]),
  requests: UnmodifiableListView([request]),
  callSchemas: const {
    'bash':
        '{"name":"bash","description":"Run a shell command",'
        '"parameters":{"type":"object","properties":{"cmd":{"type":"string"}}}}',
  },
  partial: null,
  runningCalls: UnmodifiableListView(const <TrajectoryRunningToolCall>[]),
  recordLocations: const {'details/assistant': 0, 'details/assistant-empty': 1},
  revision: 1,
);
