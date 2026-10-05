// Golden fixture corpus for the Agent Wire Protocol (issue #1101 slice 1).
//
// The corpus under `fixtures/v1/` is the conformance pin: every live event
// and command kind has one canonical frame, and both the Dart implementation
// and every future sdk/ reference client must reproduce it exactly
// (parse all fixture frames, emit the pinned command frames).
//
// The loader fails LOUD on structure problems (missing keys, wrong types,
// kind mismatches) — a silently half-parsed fixture would pin nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:flutter_agent_harness/src/tools/request_secret_tool.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:flutter_agent_harness/src/agent/tool_pairing.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_blobs.dart';
import 'package:flutter_agent_harness/src/trajectory/trajectory_record.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';

/// Directory holding the v1 event fixtures.
const String eventFixturesDir = 'test/wire/fixtures/v1/events';

/// Wire kinds that decode to [RequestWireEvent] — host-interaction request
/// frames, not native [AgentEvent]s.
const Set<String> requestEventKinds = {
  'approval_request',
  'ask_request',
  'secret_request',
};

/// Wire kinds a SERVER emits without a native [AgentEvent] counterpart
/// (`fa wire-serve`, issue #1103): they decode as the documented unknown
/// passthrough on the host side and have no native round-trip builder.
const Set<String> serverEventKinds = {'error'};

/// Directory holding the v1 command fixtures.
const String commandFixturesDir = 'test/wire/fixtures/v1/commands';

/// One parsed golden fixture: [frame] is the canonical wire frame for
/// [kind] at [protocolVersion].
final class GoldenFixture {
  GoldenFixture({
    required this.kind,
    required this.protocolVersion,
    required this.frame,
    required this.path,
  });

  final String kind;
  final int protocolVersion;
  final Map<String, dynamic> frame;
  final String path;
}

/// Loads every `*.json` fixture under [dirPath], loud on any structure
/// problem. Sorted by path so test failures are deterministic.
List<GoldenFixture> loadGoldenFixtures(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    throw StateError('Golden fixture directory missing: $dirPath');
  }
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    throw StateError('No golden fixtures found under $dirPath');
  }
  final fixtures = <GoldenFixture>[];
  for (final file in files) {
    final doc = jsonDecode(file.readAsStringSync());
    void invalid(String message) => throw StateError('${file.path}: $message');
    if (doc is! Map<String, dynamic>) {
      invalid('top level must be a JSON object');
    }
    for (final key in const ['kind', 'protocolVersion', 'frame']) {
      if (!doc.containsKey(key)) invalid('missing required key "$key"');
    }
    final kind = doc['kind'];
    if (kind is! String || kind.isEmpty) {
      invalid('"kind" must be a non-empty string');
    }
    final version = doc['protocolVersion'];
    if (version is! int) invalid('"protocolVersion" must be an int');
    final frame = doc['frame'];
    if (frame is! Map<String, dynamic>) {
      invalid('"frame" must be a JSON object');
    }
    if (frame['kind'] != kind) {
      invalid('frame.kind (${frame['kind']}) != fixture.kind ($kind)');
    }
    if (frame['v'] != version) {
      invalid('frame.v (${frame['v']}) != protocolVersion ($version)');
    }
    fixtures.add(
      GoldenFixture(
        kind: kind,
        protocolVersion: version,
        frame: frame,
        path: file.path,
      ),
    );
  }
  return fixtures;
}

/// Fixed epoch millis used by every fixture timestamp — goldens are static.
const int fixtureTimestampMs = 1727673600000;

/// The fixed assistant message shared by the message fixtures.
AssistantMessage fixtureAssistantMessage({String? text}) => AssistantMessage(
  content: text == null ? const [] : [TextContent(text: text)],
  api: 'openai-completions',
  provider: 'openai',
  model: 'gpt-test',
  usage: const Usage(
    input: 1,
    output: 2,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 3,
    cost: UsageCost(),
  ),
  stopReason: StopReason.stop,
  timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
);

/// The fixed tool-call partial used by the tool-call streaming fixtures:
/// thinking block at index 0, tool call at index 1, stopReason toolUse.
AssistantMessage fixtureThinkingToolPartial() => AssistantMessage(
  content: const [
    ThinkingContent(thinking: 'pondering'),
    ToolCall(id: 'call_1', name: 'bash', arguments: {'command': 'ls'}),
  ],
  api: 'openai-completions',
  provider: 'openai',
  model: 'gpt-test',
  usage: fixtureAssistantMessage().usage,
  stopReason: StopReason.toolUse,
  timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
);

/// The fixed error partial used by the error fixture.
AssistantMessage fixtureErrorPartial() => AssistantMessage(
  content: const [],
  api: 'openai-completions',
  provider: 'openai',
  model: 'gpt-test',
  usage: fixtureAssistantMessage().usage,
  stopReason: StopReason.error,
  errorMessage: 'provider 429',
  timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
);

/// The fixed user message ("hi") used by the message fixtures.
UserMessage fixtureUserMessage() => UserMessage.text(
  'hi',
  timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
);

/// The fixed tool result used by the tool fixtures.
ToolResultMessage fixtureToolResult() => ToolResultMessage(
  toolCallId: 'call_1',
  toolName: 'bash',
  content: const [TextContent(text: 'ok')],
  isError: false,
  timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
);

/// Builds the NATIVE Dart event a fixture pins, independent of the wire
/// implementation: the test encodes this through the protocol and requires
/// the fixture frame byte-for-byte (well, deep-equal).
AgentEvent nativeEventFor(String kind) => switch (kind) {
  'agent_start' => const AgentStartEvent(),
  'agent_settled' => const AgentSettledEvent(),
  'turn_start' => const TurnStartEvent(),
  'agent_end' => AgentEndEvent([
    fixtureUserMessage(),
    fixtureAssistantMessage(text: 'Hello'),
  ]),
  'turn_end' => TurnEndEvent(
    message: fixtureAssistantMessage(text: 'Hello'),
    toolResults: [fixtureToolResult()],
  ),
  'message_start' => MessageStartEvent(fixtureUserMessage()),
  'message_end' => MessageEndEvent(fixtureAssistantMessage(text: 'Hello')),
  'tool_execution_start' => ToolExecutionStartEvent(
    toolCallId: 'call_1',
    toolName: 'bash',
    args: const {'command': 'ls -la'},
    timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
  ),
  'tool_execution_update' => ToolExecutionUpdateEvent(
    toolCallId: 'call_1',
    toolName: 'bash',
    args: const {'command': 'ls -la'},
    partialResult: const ToolExecutionResult(
      content: [TextContent(text: 'partial')],
    ),
  ),
  'tool_execution_end' => const ToolExecutionEndEvent(
    toolCallId: 'call_1',
    toolName: 'bash',
    result: ToolExecutionResult(content: [TextContent(text: 'done')]),
    isError: false,
  ),
  'model_request' => ModelRequestEvent(
    detail: TrajectoryRequestDetail(
      messageCount: 2,
      systemPromptChars: 120,
      toolCount: 1,
      toolNames: const ['bash'],
      messages: const [
        TrajectoryRequestMessageSummary(role: 'user', chars: 2, preview: 'hi'),
      ],
      systemPromptHash: 'sha:abc',
      toolManifestHash: 'sha:def',
    ),
    promptBlob: const TrajectoryPromptBlob(
      hash: 'sha:abc',
      text: 'system prompt',
    ),
    manifestBlob: TrajectoryToolManifestBlob(
      hash: 'sha:def',
      tools: [
        TrajectoryToolManifestEntry(
          name: 'bash',
          description: 'runs a command',
          schemaJson: '{}',
          schemaChars: 2,
          schemaTruncated: false,
        ),
      ],
    ),
    rawWireDump: '<raw-wire-dump-secret>',
  ),
  'tool_pairing_repair' => const ToolPairingRepairEvent(
    report: ToolPairingRepairReport(
      droppedResultIds: ['call_9'],
      synthesizedResultIds: ['call_7'],
      renamedIds: [(from: 'call_1', to: 'call_1_renamed')],
    ),
    providerError: 'unexpected tool_use_id',
  ),
  'tool_call_heartbeat' => ToolCallHeartbeatEvent(
    toolCallId: 'call_1',
    toolName: 'bash',
    args: const {'command': 'sleep 600'},
    elapsed: const Duration(seconds: 61),
    outputBytes: 12,
    attempt: 1,
    timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
  ),
  'tool_call_stuck' => ToolCallStuckEvent(
    toolCallId: 'call_1',
    toolName: 'bash',
    args: const {'command': 'sleep 600'},
    elapsed: const Duration(seconds: 3),
    action: StuckFollowUpAction.cancelRetry,
    detail: '300s stuck threshold exceeded',
    timestamp: DateTime.fromMillisecondsSinceEpoch(fixtureTimestampMs),
  ),
  _ => throw StateError('No native event builder pinned for kind "$kind"'),
};

/// Builds the native message_update variant a fixture file pins. The file
/// name suffix (after `message_update_`) selects the nested provider event.
AgentEvent nativeMessageUpdateFor(String fileName) {
  final message = switch (fileName) {
    _ when fileName.startsWith('message_update_tool_call') =>
      fixtureThinkingToolPartial(),
    _ when fileName == 'message_update_error' => fixtureErrorPartial(),
    _ => fixtureAssistantMessage(text: 'Hello'),
  };
  final partial = message;
  final AssistantMessageEvent nested = switch (fileName) {
    'message_update_start' => StartEvent(partial: partial),
    'message_update_text_start' => TextStartEvent(
      contentIndex: 0,
      partial: partial,
    ),
    'message_update_text_delta' => TextDeltaEvent(
      contentIndex: 0,
      delta: 'Hel',
      partial: partial,
    ),
    'message_update_text_end' => TextEndEvent(
      contentIndex: 0,
      content: 'Hello',
      partial: partial,
    ),
    'message_update_thinking_start' => ThinkingStartEvent(
      contentIndex: 0,
      partial: partial,
    ),
    'message_update_thinking_delta' => ThinkingDeltaEvent(
      contentIndex: 0,
      delta: 'hmm',
      partial: partial,
    ),
    'message_update_thinking_end' => ThinkingEndEvent(
      contentIndex: 0,
      content: 'pondering',
      partial: partial,
    ),
    'message_update_tool_call_start' => ToolCallStartEvent(
      contentIndex: 1,
      partial: partial,
    ),
    'message_update_tool_call_delta' => ToolCallDeltaEvent(
      contentIndex: 1,
      delta: '{"command":',
      partial: partial,
    ),
    'message_update_tool_call_end' => ToolCallEndEvent(
      contentIndex: 1,
      toolCall: const ToolCall(
        id: 'call_1',
        name: 'bash',
        arguments: {'command': 'ls'},
      ),
      partial: partial,
    ),
    'message_update_done' => DoneEvent(
      reason: StopReason.stop,
      message: fixtureAssistantMessage(text: 'Hello'),
    ),
    'message_update_error' => ErrorEvent(
      reason: StopReason.error,
      error: fixtureErrorPartial(),
      retryAfter: const Duration(milliseconds: 2000),
    ),
    _ => throw StateError('No nested provider event pinned for "$fileName"'),
  };
  return MessageUpdateEvent(message: message, assistantMessageEvent: nested);
}

/// Builds the NATIVE command a fixture pins: the protocol's typed command
/// object, whose wire frame must equal the fixture frame.
WireCommand nativeCommandFor(String kind) => switch (kind) {
  'prompt' => const WirePromptCommand('list the files'),
  'steer' => const WireSteerCommand('stop and use git instead'),
  'abort' => const WireAbortCommand(),
  'approval_response' => const WireApprovalResponseCommand(
    id: 'ap_1',
    decision: ApprovalDecision.approveOnce,
  ),
  'ask_response' => const WireAskResponseCommand(
    id: 'ask_1',
    answers: [
      AskAnswer(selected: ['Postgres']),
      AskAnswer(freeText: 'none'),
    ],
  ),
  'secret_response' => const WireSecretResponseCommand(
    id: 'sec_1',
    result: RequestSecretResult(
      name: 'MY_API_TOKEN',
      value: '<secret>',
      persisted: true,
    ),
  ),
  'session_control' => const WireSessionControlCommand(
    op: 'ping',
    params: {'x': 1},
  ),
  _ => throw StateError('No native command builder pinned for kind "$kind"'),
};

/// The native approval request the approval_request fixture pins.
ApprovalRequest nativeApprovalRequest() => const ApprovalRequest(
  toolName: 'bash',
  tier: ApprovalTier.exec,
  arguments: {'command': 'rm -rf /tmp/x'},
  reason: 'critical pattern matched',
);

/// The native questions the ask_request fixture pins.
List<AskQuestion> nativeAskQuestions() => const [
  AskQuestion(
    question: 'Which database?',
    options: [
      AskOption(label: 'Postgres', description: 'relational'),
      AskOption(label: 'SQLite'),
    ],
    multiSelect: false,
    recommended: 0,
  ),
  AskQuestion(question: 'Notes?'),
];

/// The native secret request inputs the secret_request fixture pins.
(String, String) nativeSecretRequest() =>
    ('MY_API_TOKEN', 'needed to call the deploy API');
