import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #695 UT tier: the stream-json encoder is a pure
/// `AgentEvent -> String?` mapping over pi's closed `JsonAgentSessionEvent`
/// set (pi `docs/json.md`): every event either maps to exactly one compact
/// JSON line or is explicitly filtered out, `message_update` lines are
/// delta-only, and images/huge tool results are bounded.
void main() {
  AssistantMessage assistant({
    List<ContentBlock> content = const [TextContent(text: 'Hello')],
    Usage usage = Usage.zero,
    StopReason stopReason = StopReason.stop,
  }) => AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );

  group('streamJsonSessionHeaderLine', () {
    test('first-line shape: session/version/id/timestamp/cwd', () {
      final line = streamJsonSessionHeaderLine(
        sessionId: 'sess-1',
        cwd: '/work',
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final json = jsonDecode(line) as Map<String, dynamic>;
      expect(json['type'], 'session');
      expect(json['version'], 1);
      expect(json['id'], 'sess-1');
      expect(json['cwd'], '/work');
      expect(json['timestamp'], isA<String>());
      expect(line, startsWith('{"type":"session"'));
    });
  });

  group('streamJsonEventLine lifecycle events', () {
    test('agent_start / turn_start / agent_settled are bare type lines', () {
      expect(
        streamJsonEventLine(const AgentStartEvent()),
        '{"type":"agent_start"}',
      );
      expect(
        streamJsonEventLine(const TurnStartEvent()),
        '{"type":"turn_start"}',
      );
      expect(
        streamJsonEventLine(const AgentSettledEvent()),
        '{"type":"agent_settled"}',
      );
    });

    test('message_start / message_end carry the full message', () {
      final message = assistant();
      for (final event in [
        MessageStartEvent(message),
        MessageEndEvent(message),
      ]) {
        final json =
            jsonDecode(streamJsonEventLine(event)!) as Map<String, dynamic>;
        expect(
          json['type'],
          event is MessageStartEvent ? 'message_start' : 'message_end',
        );
        expect(json['message'], message.toJson());
      }
    });

    test('message_end carries cumulative usage (AC8)', () {
      const usage = Usage(
        input: 10,
        output: 5,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 15,
        cost: UsageCost(input: 0.1, output: 0.2, total: 0.3),
      );
      final json =
          jsonDecode(
                streamJsonEventLine(MessageEndEvent(assistant(usage: usage)))!,
              )
              as Map<String, dynamic>;
      expect(json['message']['usage'], usage.toJson());
    });

    test('turn_end carries message and toolResults', () {
      final message = assistant();
      final toolResult = ToolResultMessage(
        toolCallId: 't1',
        toolName: 'read',
        content: const [TextContent(text: 'ok')],
        isError: false,
        timestamp: DateTime.utc(2026),
      );
      final json =
          jsonDecode(
                streamJsonEventLine(
                  TurnEndEvent(message: message, toolResults: [toolResult]),
                )!,
              )
              as Map<String, dynamic>;
      expect(json['type'], 'turn_end');
      expect(json['message'], message.toJson());
      expect((json['toolResults'] as List).single, toolResult.toJson());
    });

    test('agent_end carries the full message list', () {
      final message = assistant();
      final json =
          jsonDecode(streamJsonEventLine(AgentEndEvent([message]))!)
              as Map<String, dynamic>;
      expect(json['type'], 'agent_end');
      expect(json['messages'], [message.toJson()]);
    });
  });

  group('streamJsonEventLine message_update is delta-only (AC3)', () {
    test('carries assistantMessageEvent + cumulative usage, no snapshot', () {
      const usage = Usage(
        input: 7,
        output: 3,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 10,
        cost: UsageCost(),
      );
      final partial = assistant(usage: usage);
      final event = MessageUpdateEvent(
        message: partial,
        assistantMessageEvent: TextDeltaEvent(
          contentIndex: 0,
          delta: 'Hi',
          partial: partial,
        ),
      );
      final json =
          jsonDecode(streamJsonEventLine(event)!) as Map<String, dynamic>;
      expect(json['type'], 'message_update');
      // Delta-only invariant: NO cumulative `message` snapshot key, and the
      // wrapped provider event carries NO `partial` snapshot either.
      expect(
        json.containsKey('message'),
        isFalse,
        reason: 'message_update must not carry a message snapshot',
      );
      expect(json['usage'], usage.toJson());
      final inner = json['assistantMessageEvent'] as Map<String, dynamic>;
      expect(inner.containsKey('partial'), isFalse);
      expect(inner['type'], 'text_delta');
      expect(inner['contentIndex'], 0);
      expect(inner['delta'], 'Hi');
    });

    test('assembling text deltas reproduces message_end text (property)', () {
      final fullText = 'stream-json keeps the wire linear';
      final partial = assistant(content: [TextContent(text: fullText)]);
      final words = fullText.split(' ');
      var assembled = '';
      var rest = fullText;
      for (final word in words) {
        // Each delta is one word plus its trailing space when one follows —
        // arbitrary chunking, like a real provider stream.
        final delta = rest.length > word.length ? '$word ' : word;
        final event = MessageUpdateEvent(
          message: partial,
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: delta,
            partial: partial,
          ),
        );
        final json =
            jsonDecode(streamJsonEventLine(event)!) as Map<String, dynamic>;
        final inner = json['assistantMessageEvent'] as Map<String, dynamic>;
        assembled += inner['delta'] as String;
        rest = rest.substring(delta.length);
      }
      expect(assembled, fullText);
      final endJson =
          jsonDecode(streamJsonEventLine(MessageEndEvent(partial))!)
              as Map<String, dynamic>;
      final endText =
          ((endJson['message'] as Map<String, dynamic>)['content'] as List)
              .whereType<Map<String, dynamic>>()
              .map((b) => b['text'])
              .join();
      expect(assembled, endText);
    });
  });

  group('assistantMessageEvent wire shapes (pi AssistantMessageEvent)', () {
    MessageUpdateEvent wrap(AssistantMessageEvent inner) => MessageUpdateEvent(
      message: inner.partial,
      assistantMessageEvent: inner,
    );

    Map<String, dynamic> decodeInner(AssistantMessageEvent inner) =>
        (jsonDecode(streamJsonEventLine(wrap(inner))!)
                as Map<String, dynamic>)['assistantMessageEvent']
            as Map<String, dynamic>;

    test('start', () {
      expect(decodeInner(StartEvent(partial: assistant())), {'type': 'start'});
    });

    test('text_start / text_delta / text_end', () {
      expect(
        decodeInner(TextStartEvent(contentIndex: 0, partial: assistant())),
        {'type': 'text_start', 'contentIndex': 0},
      );
      expect(
        decodeInner(
          TextEndEvent(contentIndex: 0, content: 'Hello', partial: assistant()),
        ),
        {'type': 'text_end', 'contentIndex': 0, 'content': 'Hello'},
      );
    });

    test('thinking_start / thinking_delta / thinking_end', () {
      expect(
        decodeInner(ThinkingStartEvent(contentIndex: 0, partial: assistant())),
        {'type': 'thinking_start', 'contentIndex': 0},
      );
      expect(
        decodeInner(
          ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'hmm',
            partial: assistant(),
          ),
        ),
        {'type': 'thinking_delta', 'contentIndex': 0, 'delta': 'hmm'},
      );
      expect(
        decodeInner(
          ThinkingEndEvent(
            contentIndex: 0,
            content: 'hmm',
            partial: assistant(),
          ),
        ),
        {'type': 'thinking_end', 'contentIndex': 0, 'content': 'hmm'},
      );
    });

    test('toolcall_start carries constant-sized id + toolName', () {
      final partial = assistant(
        content: const [
          ToolCall(id: 't1', name: 'read', arguments: {'path': 'a.txt'}),
        ],
      );
      expect(
        decodeInner(ToolCallStartEvent(contentIndex: 0, partial: partial)),
        {
          'type': 'toolcall_start',
          'contentIndex': 0,
          'id': 't1',
          'toolName': 'read',
        },
      );
    });

    test('toolcall_delta / toolcall_end', () {
      const call = ToolCall(
        id: 't1',
        name: 'read',
        arguments: {'path': 'a.txt'},
      );
      expect(
        decodeInner(
          ToolCallDeltaEvent(
            contentIndex: 0,
            delta: '{"pa',
            partial: assistant(content: const [call]),
          ),
        ),
        {'type': 'toolcall_delta', 'contentIndex': 0, 'delta': '{"pa'},
      );
      expect(
        decodeInner(
          ToolCallEndEvent(
            contentIndex: 0,
            toolCall: call,
            partial: assistant(content: const [call]),
          ),
        ),
        {'type': 'toolcall_end', 'contentIndex': 0, 'toolCall': call.toJson()},
      );
    });

    test('done / error', () {
      expect(
        decodeInner(DoneEvent(reason: StopReason.stop, message: assistant())),
        {'type': 'done', 'reason': 'stop'},
      );
      expect(
        decodeInner(
          ErrorEvent(
            reason: StopReason.error,
            error: assistant(stopReason: StopReason.error, usage: Usage.zero),
          ),
        ),
        containsPair('type', 'error'),
      );
    });
  });

  group('streamJsonEventLine tool execution events', () {
    test('tool_execution_start carries toolCallId/toolName/args (AC4)', () {
      final json =
          jsonDecode(
                streamJsonEventLine(
                  ToolExecutionStartEvent(
                    toolCallId: 't1',
                    toolName: 'read',
                    args: const {'path': 'a.txt'},
                    timestamp: DateTime.utc(2026),
                  ),
                )!,
              )
              as Map<String, dynamic>;
      expect(json, {
        'type': 'tool_execution_start',
        'toolCallId': 't1',
        'toolName': 'read',
        'args': {'path': 'a.txt'},
      });
    });

    test('tool_execution_update carries partialResult', () {
      final json =
          jsonDecode(
                streamJsonEventLine(
                  ToolExecutionUpdateEvent(
                    toolCallId: 't1',
                    toolName: 'read',
                    args: const {'path': 'a.txt'},
                    partialResult: const ToolExecutionResult(
                      content: [TextContent(text: 'half')],
                    ),
                  ),
                )!,
              )
              as Map<String, dynamic>;
      expect(json['type'], 'tool_execution_update');
      expect(json['toolCallId'], 't1');
      expect(json['toolName'], 'read');
      // pi's shape: partialResult only — the args already went out with
      // tool_execution_start under the same toolCallId; re-sending them
      // would grow the stream quadratically on chatty updates.
      expect(json.containsKey('args'), isFalse);
      expect((json['partialResult'] as Map)['content'], [
        const TextContent(text: 'half').toJson(),
      ]);
    });

    test('tool_execution_end carries result + isError (AC4)', () {
      final json =
          jsonDecode(
                streamJsonEventLine(
                  ToolExecutionEndEvent(
                    toolCallId: 't1',
                    toolName: 'read',
                    result: const ToolExecutionResult(
                      content: [TextContent(text: 'ok')],
                    ),
                    isError: false,
                  ),
                )!,
              )
              as Map<String, dynamic>;
      expect(json, {
        'type': 'tool_execution_end',
        'toolCallId': 't1',
        'toolName': 'read',
        'result': {
          'content': [const TextContent(text: 'ok').toJson()],
          'terminate': false,
        },
        'isError': false,
      });
    });

    test('huge tool result text is capped and stays one line (E3)', () {
      final huge = 'x' * (streamJsonMaxToolResultChars + 5000);
      final line = streamJsonEventLine(
        ToolExecutionEndEvent(
          toolCallId: 't1',
          toolName: 'read',
          result: ToolExecutionResult(content: [TextContent(text: huge)]),
          isError: false,
        ),
      )!;
      expect(line.contains('\n'), isFalse, reason: 'one JSON line only');
      final json = jsonDecode(line) as Map<String, dynamic>;
      final text =
          (((json['result'] as Map)['content'] as List).single
                  as Map<String, dynamic>)['text']
              as String;
      expect(text.length, lessThan(huge.length));
      expect(text, contains('(+'));
    });

    test('image content serializes as a placeholder, never base64 (E5)', () {
      const image = ImageContent(data: 'aGVsbG8=', mimeType: 'image/png');
      final message = assistant(content: const [image]);
      final json =
          jsonDecode(streamJsonEventLine(MessageEndEvent(message))!)
              as Map<String, dynamic>;
      final block = ((json['message'] as Map)['content'] as List).single as Map;
      expect(block['type'], 'image');
      expect(block['mimeType'], 'image/png');
      expect(block['data'], isNot('aGVsbG8='));
      expect(block['data'], isA<String>());
    });
  });

  group('triage: every AgentEvent subtype is mapped or filtered (AC2)', () {
    test('exhaustive — nothing slips in or silently vanishes', () {
      const detail = TrajectoryRequestDetail(
        messageCount: 1,
        systemPromptChars: 10,
        toolCount: 0,
        toolNames: [],
        messages: [],
      );
      final message = assistant();
      final partial = assistant();
      // Every concrete AgentEvent subtype, one sample each. The count
      // tripwire below breaks when a NEW subtype joins the sealed
      // hierarchy, forcing triage here (mapped or explicitly filtered) —
      // the encoder's defaulted switches cannot force it at compile time.
      final samples = <AgentEvent>[
        const AgentStartEvent(),
        AgentEndEvent([message]),
        const AgentSettledEvent(),
        const TurnStartEvent(),
        TurnEndEvent(message: message, toolResults: const []),
        MessageStartEvent(message),
        MessageUpdateEvent(
          message: partial,
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: 'x',
            partial: partial,
          ),
        ),
        MessageEndEvent(message),
        ToolExecutionStartEvent(
          toolCallId: 't1',
          toolName: 'read',
          args: const {},
          timestamp: DateTime.utc(2026),
        ),
        ToolExecutionUpdateEvent(
          toolCallId: 't1',
          toolName: 'read',
          args: const {},
          partialResult: const ToolExecutionResult(content: []),
        ),
        ToolExecutionEndEvent(
          toolCallId: 't1',
          toolName: 'read',
          result: const ToolExecutionResult(content: []),
          isError: false,
        ),
        const ModelRequestEvent(detail: detail),
        const ToolPairingRepairEvent(report: ToolPairingRepairReport()),
      ];
      // Tripwire: exactly the sealed hierarchy's current size. A new
      // AgentEvent subtype must be added above (and classified in
      // `filtered` or mapped) — this count is what makes the omission
      // visible.
      expect(samples, hasLength(13));
      const filtered = {'ModelRequestEvent', 'ToolPairingRepairEvent'};
      for (final event in samples) {
        final line = streamJsonEventLine(event);
        final name = event.runtimeType.toString();
        if (filtered.contains(name)) {
          expect(
            line,
            isNull,
            reason: '$name must be filtered out of the stream',
          );
        } else {
          expect(
            line,
            isNotNull,
            reason: '$name must map to a stream-json line',
          );
          final json = jsonDecode(line!) as Map<String, dynamic>;
          expect(json.containsKey('type'), isTrue);
        }
      }
    });

    test('every AssistantMessageEvent subtype is serialized (count '
        'tripwire, AC2)', () {
      final message = assistant();
      const call = ToolCall(id: 't1', name: 'read', arguments: {});
      // Every concrete AssistantMessageEvent subtype, one sample each.
      // The count tripwire below breaks when a NEW subtype joins the
      // sealed hierarchy, forcing a wire shape here — the encoder's
      // defaulted switches cannot force it at compile time, and without
      // this the new subtype would hit an untriaged default arm (a
      // contained-throw warning line) instead of its intended shape.
      final samples = <AssistantMessageEvent>[
        StartEvent(partial: message),
        TextStartEvent(contentIndex: 0, partial: message),
        TextDeltaEvent(contentIndex: 0, delta: 'x', partial: message),
        TextEndEvent(contentIndex: 0, content: 'x', partial: message),
        ThinkingStartEvent(contentIndex: 0, partial: message),
        ThinkingDeltaEvent(contentIndex: 0, delta: 'x', partial: message),
        ThinkingEndEvent(contentIndex: 0, content: 'x', partial: message),
        ToolCallStartEvent(contentIndex: 0, partial: message),
        ToolCallDeltaEvent(contentIndex: 0, delta: '{', partial: message),
        ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: message),
        DoneEvent(reason: StopReason.stop, message: message),
        ErrorEvent(reason: StopReason.error, error: message),
      ];
      // Tripwire: exactly the sealed hierarchy's current size (mirror
      // of the AgentEvent hasLength(13) one). A new subtype must be
      // added above AND given its wire shape below — this count is
      // what makes the omission visible.
      expect(samples, hasLength(12));
      const wireTypes = <String, String>{
        'StartEvent': 'start',
        'TextStartEvent': 'text_start',
        'TextDeltaEvent': 'text_delta',
        'TextEndEvent': 'text_end',
        'ThinkingStartEvent': 'thinking_start',
        'ThinkingDeltaEvent': 'thinking_delta',
        'ThinkingEndEvent': 'thinking_end',
        'ToolCallStartEvent': 'toolcall_start',
        'ToolCallDeltaEvent': 'toolcall_delta',
        'ToolCallEndEvent': 'toolcall_end',
        'DoneEvent': 'done',
        'ErrorEvent': 'error',
      };
      for (final event in samples) {
        final name = event.runtimeType.toString();
        final line = streamJsonEventLine(
          MessageUpdateEvent(message: message, assistantMessageEvent: event),
        );
        expect(line, isNotNull, reason: '$name must serialize');
        final inner =
            (jsonDecode(line!) as Map<String, dynamic>)['assistantMessageEvent']
                as Map<String, dynamic>;
        expect(
          inner['type'],
          wireTypes[name],
          reason:
              '$name must map to its ${wireTypes[name]} wire shape, not the '
              'untriaged-default degrade path',
        );
      }
    });

    test('filtered wire names never appear as event types', () {
      const detail = TrajectoryRequestDetail(
        messageCount: 1,
        systemPromptChars: 10,
        toolCount: 0,
        toolNames: [],
        messages: [],
      );
      expect(
        streamJsonEventLine(const ModelRequestEvent(detail: detail)),
        isNull,
      );
      expect(
        streamJsonEventLine(
          const ToolPairingRepairEvent(report: ToolPairingRepairReport()),
        ),
        isNull,
      );
    });
  });

  group('StreamJsonWriter', () {
    test('writes the header once, then one line per event', () {
      final lines = <String>[];
      final writer = StreamJsonWriter(emit: lines.add);
      writer
        ..writeHeader(sessionId: 'sess-1', cwd: '/work')
        ..writeHeader(sessionId: 'sess-2', cwd: '/other');
      expect(lines, hasLength(1));
      expect(
        (jsonDecode(lines.single) as Map<String, dynamic>)['id'],
        'sess-1',
      );
      lines.clear();
      writer.handleEvent(const AgentStartEvent(), null);
      writer.handleEvent(
        const ModelRequestEvent(
          detail: TrajectoryRequestDetail(
            messageCount: 1,
            systemPromptChars: 10,
            toolCount: 0,
            toolNames: [],
            messages: [],
          ),
        ),
        null,
      );
      writer.handleEvent(const AgentSettledEvent(), null);
      expect(lines, ['{"type":"agent_start"}', '{"type":"agent_settled"}']);
    });

    test('a projection hiccup degrades to a warning line, never a throw '
        '(graceful degrade)', () async {
      final lines = <String>[];
      final writer = StreamJsonWriter(emit: lines.add);
      // Same class of failure as an untriaged AssistantMessageEvent
      // subtype reaching a default arm: an unencodable value inside the
      // event (a non-finite provider-reported cost) makes the mapping
      // throw. The writer must contain it — the run streams on with a
      // skippable `warning` line (the header's `version` contract),
      // never a dead run.
      const usage = Usage(
        input: 10,
        output: 5,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 15,
        cost: UsageCost(total: double.nan),
      );
      final message = assistant(usage: usage);
      await writer.handleEvent(
        MessageUpdateEvent(
          message: message,
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: 'x',
            partial: message,
          ),
        ),
        null,
      );
      await writer.handleEvent(const AgentSettledEvent(), null);
      expect(lines, hasLength(2));
      final warning = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(warning['type'], 'warning');
      expect(warning['eventType'], 'MessageUpdateEvent');
      expect(
        (warning['message'] as String),
        contains('stream-json projection failed'),
      );
      expect(
        jsonDecode(lines.last) as Map<String, dynamic>,
        containsPair('type', 'agent_settled'),
      );
    });
  });
}
