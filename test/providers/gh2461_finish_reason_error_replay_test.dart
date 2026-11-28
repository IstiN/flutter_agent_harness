import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2461 REG (candidate 1 + named mechanism): the retry path.
///
/// The Argon incident clip shows `[net] connection lost (Provider
/// finish_reason: error) — retrying` inside the identical-read loop window.
/// Two facts are pinned here:
///
/// 1. The vendor `finish_reason: "error"` word is UNKNOWN to the
///    classification table and the #312 default classes it TRANSIENT — the
///    transient ladder replays the identical request. This is the mechanism
///    that fed the pattern-locked model one more identical-context decode
///    per loop cycle (named "other" root cause in outputs/rca.md).
/// 2. The replay appends NO duplicate assistant+toolResult pair: the
///    transcript grows exactly +2 messages per loop turn (one assistant
///    call + its result), each tool call executes exactly once — the
///    literal "retry duplication" candidate is refuted at harness level.
///    The identical repeat itself was previously UNBOUNDED (the loop-guard
///    gap; guarded by `identicalCallNoticeThreshold` — see
///    test/agent/loop_guard_test.dart; this script stays below the notice
///    threshold so both shapes stay valid).
void main() {
  const model = Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test-provider',
    baseUrl: 'https://example.test',
    contextWindow: 100000,
    maxTokens: 4096,
  );

  AssistantMessage assistant({
    List<ContentBlock> content = const [],
    StopReason stopReason = StopReason.stop,
    String? errorMessage,
    String? rawStopReason,
  }) => AssistantMessage(
    content: content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    rawStopReason: rawStopReason,
    timestamp: DateTime.utc(2026),
  );

  ToolCall readCall(String id) => ToolCall(
    id: id,
    name: 'read',
    arguments: {'path': '/tmp/wt/js/sm/verdictAndFailState.js'},
  );

  List<AssistantMessageEvent> toolTurn(ToolCall call) => [
    StartEvent(partial: assistant()),
    ToolCallStartEvent(contentIndex: 0, partial: assistant()),
    ToolCallEndEvent(
      contentIndex: 0,
      toolCall: call,
      partial: assistant(content: [call]),
    ),
    DoneEvent(
      reason: StopReason.toolUse,
      message: assistant(content: [call], stopReason: StopReason.toolUse),
    ),
  ];

  List<AssistantMessageEvent> textTurn(String text) => [
    StartEvent(partial: assistant()),
    TextStartEvent(contentIndex: 0, partial: assistant()),
    TextDeltaEvent(
      contentIndex: 0,
      delta: text,
      partial: assistant(content: [TextContent(text: text)]),
    ),
    DoneEvent(
      reason: StopReason.stop,
      message: assistant(content: [TextContent(text: text)]),
    ),
  ];

  List<AssistantMessageEvent> preCommitFinishReasonError() => [
    StartEvent(partial: assistant()),
    ErrorEvent(
      reason: StopReason.error,
      error: assistant(
        stopReason: StopReason.error,
        errorMessage: 'Provider finish_reason: error',
        rawStopReason: 'error',
      ),
    ),
  ];

  test(
    'the wire finish_reason "error" word is UNKNOWN → ladder-transient',
    () async {
      final message = assistant(
        stopReason: StopReason.error,
        errorMessage: 'Provider finish_reason: error',
        rawStopReason: 'error',
      );
      // `error` is in NEITHER classification table — the #312 unknown-word
      // bucket. The transient ladder treats unknown as replayable
      // (`retryClass != terminal`), which the replay test below observes.
      expect(finishReasonRetryClass(message), FinishReasonClass.unknown);
      expect(
        classifyFinishReason('network_error'),
        FinishReasonClass.transient,
      );
      // The terminal family is not disturbed.
      final filtered = assistant(
        stopReason: StopReason.error,
        errorMessage: 'Provider finish_reason: content_filter',
        rawStopReason: 'content_filter',
      );
      expect(finishReasonRetryClass(filtered), FinishReasonClass.terminal);
    },
  );

  test(
    'a finish_reason:error replay appends no duplicate pair (+2 per turn)',
    () async {
      final turns = <List<AssistantMessageEvent>>[
        toolTurn(readCall('call-1')),
        // The gateway dies pre-commit with the vendor finish word…
        preCommitFinishReasonError(),
        // …the ladder replays THE SAME request and the model repeats.
        toolTurn(readCall('call-2')),
        toolTurn(readCall('call-3')),
        // A text answer ends the scripted run (below the guard's notice
        // threshold — see loop_guard_test.dart for the bounded shape).
        textTurn('done'),
      ];

      final contextRoles = <List<String>>[];
      var served = 0;
      AssistantMessageEventStream fakeCall(
        Model _,
        Context context, {
        CancelToken? cancelToken,
      }) {
        // Snapshot roles: the loop MUTATES the context it hands out.
        contextRoles.add([for (final m in context.messages) m.role]);
        final out = AssistantMessageEventStream();
        final turn = turns[served.clamp(0, turns.length - 1)];
        served++;
        unawaited(
          Future(() async {
            for (final event in turn) {
              out.push(event);
            }
            out.end();
          }),
        );
        return out;
      }

      final realSleeper = transientRetrySleeper;
      transientRetrySleeper = (delay, token) async => true;
      final executed = <ToolCall>[];
      try {
        final stream = agentLoop(
          prompts: [UserMessage.text('go')],
          context: Context(
            messages: [],
            tools: [
              const Tool(name: 'read', description: 'read', parameters: {}),
            ],
          ),
          config: const AgentLoopConfig(model: model),
          streamFunction: transientRetryStreamFunction(
            fakeCall,
            maxAttempts: 3,
          ),
          toolExecutor: (toolCall, cancelToken, _) async {
            executed.add(toolCall);
            return ToolExecutionResult.text('file contents');
          },
        );
        await stream.toList();
        final transcript = await stream.result;
        // Each call executed exactly once — no dead call replayed.
        expect(executed.map((c) => c.id), ['call-1', 'call-2', 'call-3']);

        // Request 1: fresh prompt. Request 2 and its replay: SAME context
        // (the +2 from turn 1). Request 4: one more exchange (+2).
        expect(contextRoles[0], ['user']);
        expect(contextRoles[1], ['user', 'assistant', 'toolResult']);
        expect(contextRoles[2], ['user', 'assistant', 'toolResult']);
        expect(contextRoles[3], [
          'user',
          'assistant',
          'toolResult',
          'assistant',
          'toolResult',
        ]);

        // The transcript keeps one clean pair per turn — never a duplicate —
        // and the scripted final text answer.
        expect(transcript.map((m) => m.role), [
          'user',
          'assistant',
          'toolResult',
          'assistant',
          'toolResult',
          'assistant',
          'toolResult',
          'assistant',
        ]);
      } finally {
        transientRetrySleeper = realSleeper;
      }
    },
  );

  test(
    'a MID-ANSWER finish_reason:error resume executes the call once',
    () async {
      final call = readCall('call-mid');
      final turns = <List<AssistantMessageEvent>>[
        // The model streams the full tool call, THEN the gateway errors.
        [
          StartEvent(partial: assistant()),
          ToolCallStartEvent(contentIndex: 0, partial: assistant()),
          ToolCallEndEvent(
            contentIndex: 0,
            toolCall: call,
            partial: assistant(content: [call]),
          ),
          ErrorEvent(
            reason: StopReason.error,
            error: assistant(
              content: [call],
              stopReason: StopReason.error,
              errorMessage: 'Provider finish_reason: error',
              rawStopReason: 'error',
            ),
          ),
        ],
        // The resumed tail attempt regenerates the call.
        toolTurn(readCall('call-tail')),
        textTurn('done'),
      ];

      var served = 0;
      AssistantMessageEventStream fakeCall(
        Model _,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final out = AssistantMessageEventStream();
        final turn = turns[served.clamp(0, turns.length - 1)];
        served++;
        unawaited(
          Future(() async {
            for (final event in turn) {
              out.push(event);
            }
            out.end();
          }),
        );
        return out;
      }

      final realSleeper = transientRetrySleeper;
      transientRetrySleeper = (delay, token) async => true;
      final executed = <ToolCall>[];
      try {
        final stream = agentLoop(
          prompts: [UserMessage.text('go')],
          context: Context(
            messages: [],
            tools: [
              const Tool(name: 'read', description: 'read', parameters: {}),
            ],
          ),
          config: const AgentLoopConfig(model: model),
          streamFunction: transientRetryStreamFunction(
            fakeCall,
            maxAttempts: 3,
          ),
          toolExecutor: (toolCall, cancelToken, _) async {
            executed.add(toolCall);
            return ToolExecutionResult.text('file contents');
          },
        );
        await stream.toList();
        final transcript = await stream.result;
        // The dead call never executed; only the regenerated twin did —
        // and only ONCE (issue #1132 r2 discipline holds through the
        // finish_reason path).
        expect(executed.map((c) => c.id), ['call-tail']);
        expect(transcript.map((m) => m.role), [
          'user',
          'assistant',
          'toolResult',
          'assistant',
        ]);
      } finally {
        transientRetrySleeper = realSleeper;
      }
    },
  );
}
