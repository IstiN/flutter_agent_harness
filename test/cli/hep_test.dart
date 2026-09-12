/// HEP v1 (Harness Event Protocol) golden frame tests — issue #155.
///
/// `--output events` turns stdout into a strict JSONL stream: one JSON
/// object per line, nothing else. These tests pin the exact byte shape of
/// every frame type against golden strings so the Go supervisor's parser
/// contract cannot drift.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';


AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

/// Collects every line a [HepWriter] emits.
class _Lines {
  final lines = <String>[];

  void emit(String line) => lines.add(line);

  /// Every line decoded as a JSON map — throws on any non-object line.
  List<Map<String, dynamic>> get frames =>
      [for (final line in lines) jsonDecode(line) as Map<String, dynamic>];
}

void main() {
  group('frame builders (goldens)', () {
    test('header pins protocol, fah version and session', () {
      expect(
        hepHeaderFrame(fahVersion: '1.2.3', sessionId: 'abc'),
        '{"type":"hep_header","hep":"v1","fah":"1.2.3","session":"abc"}',
      );
    });

    test('agent_start carries the turn id', () {
      expect(
        hepAgentStartFrame(turnId: 1),
        '{"type":"agent_start","turn_id":1}',
      );
    });

    test('message_start carries role', () {
      expect(
        hepMessageStartFrame(turnId: 1, role: 'assistant'),
        '{"type":"message_start","turn_id":1,"role":"assistant"}',
      );
    });

    test('message_delta carries the text delta', () {
      expect(
        hepMessageDeltaFrame(turnId: 1, delta: 'hel"lo\n'),
        '{"type":"message_delta","turn_id":1,"delta":"hel\\"lo\\n"}',
      );
    });

    test('tool_start carries id, name and args summary', () {
      expect(
        hepToolStartFrame(
          turnId: 1,
          id: 'c1',
          name: 'read',
          argsSummary: 'path="notes.txt"',
        ),
        '{"type":"tool_start","turn_id":1,"id":"c1","name":"read",'
        '"args_summary":"path=\\"notes.txt\\""}',
      );
    });

    test('tool_delta carries id and update', () {
      expect(
        hepToolDeltaFrame(turnId: 1, id: 'c1', update: 'partial'),
        '{"type":"tool_delta","turn_id":1,"id":"c1","update":"partial"}',
      );
    });

    test('turn_done carries message, tool_results, usage, stop_reason', () {
      expect(
        hepTurnDoneFrame(
          turnId: 1,
          message: 'done reading',
          toolResults: const [
            {'id': 'c1', 'name': 'read', 'ok': true, 'text': 'data'},
          ],
          usage: const Usage(
            input: 12,
            output: 34,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 46,
            cost: UsageCost(total: 0.5),
          ),
          stopReason: 'stop',
        ),
        '{"type":"turn_done","turn_id":1,"message":"done reading",'
        '"tool_results":[{"id":"c1","name":"read","ok":true,"text":"data"}],'
        '"usage":{"input":12,"output":34,"cost":0.5},"stop_reason":"stop"}',
      );
    });

    test('turn_error carries error and fatality', () {
      expect(
        hepTurnErrorFrame(turnId: 1, error: 'provider boom', fatal: true),
        '{"type":"turn_error","turn_id":1,"error":"provider boom","fatal":true}',
      );
    });

    test('cancelled carries the turn id', () {
      expect(
        hepCancelledFrame(turnId: 1),
        '{"type":"cancelled","turn_id":1}',
      );
    });

    test('compaction frames bracket a compaction run', () {
      expect(
        hepCompactionStartFrame(1),
        '{"type":"compaction_start","turn_id":1}',
      );
      expect(
        hepCompactionEndFrame(1, 4200),
        '{"type":"compaction_end","turn_id":1,"tokens_freed":4200}',
      );
    });
  });

  group('HepWriter', () {
    test('header is the first line', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      hep.writeHeader(sessionId: 'sess-1');
      expect(
        out.lines.single,
        '{"type":"hep_header","hep":"v1","fah":"9.9.9","session":"sess-1"}',
      );
    });

    test('a streamed text turn emits the full ordered frame set', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      final partial = _assistant(content: [TextContent(text: 'hi there')]);
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        MessageStartEvent(_assistant()),
        CancelTokenSource().token,
      );
      await hep.handleEvent(
        MessageUpdateEvent(
          message: partial,
          assistantMessageEvent: TextDeltaEvent(
            contentIndex: 0,
            delta: 'hi there',
            partial: partial,
          ),
        ),
        CancelTokenSource().token,
      );
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(content: [TextContent(text: 'hi there')]),
          toolResults: const [],
        ),
        CancelTokenSource().token,
      );

      expect(out.lines, [
        '{"type":"agent_start","turn_id":1}',
        '{"type":"message_start","turn_id":1,"role":"assistant"}',
        '{"type":"message_delta","turn_id":1,"delta":"hi there"}',
        '{"type":"turn_done","turn_id":1,"message":"hi there",'
            '"tool_results":[],"usage":{"input":0,"output":0,"cost":0.0},'
            '"stop_reason":"stop"}',
      ]);
      // Every line is exactly one JSON object.
      expect(out.frames, hasLength(4));
    });

    test('thinking deltas are never message_delta frames', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      final partial = _assistant(
        content: [ThinkingContent(thinking: 'pondering')],
      );
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        MessageUpdateEvent(
          message: partial,
          assistantMessageEvent: ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'pondering',
            partial: partial,
          ),
        ),
        CancelTokenSource().token,
      );
      expect(out.lines.where((l) => l.contains('message_delta')), isEmpty);
    });

    test('a tool call shares the turn id; next turn increments it', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'read',
          args: const {'path': 'notes.txt'},
          timestamp: DateTime.utc(2026),
        ),
        CancelTokenSource().token,
      );
      await hep.handleEvent(
        ToolExecutionUpdateEvent(
          toolCallId: 'c1',
          toolName: 'read',
          args: const {'path': 'notes.txt'},
          partialResult: ToolExecutionResult.text('partial data'),
        ),
        CancelTokenSource().token,
      );
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(
            content: [
              ToolCall(id: 'c1', name: 'read', arguments: const {}),
            ],
            stopReason: StopReason.toolUse,
          ),
          toolResults: [
            ToolResultMessage(
              toolCallId: 'c1',
              toolName: 'read',
              content: [TextContent(text: 'data')],
              isError: false,
              timestamp: DateTime.utc(2026),
            ),
          ],
        ),
        CancelTokenSource().token,
      );
      // Second LLM round-trip = a new turn id.
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(content: [TextContent(text: 'done')]),
          toolResults: const [],
        ),
        CancelTokenSource().token,
      );

      expect(out.lines, [
        '{"type":"agent_start","turn_id":1}',
        '{"type":"tool_start","turn_id":1,"id":"c1","name":"read",'
            '"args_summary":"path=\\"notes.txt\\""}',
        '{"type":"tool_delta","turn_id":1,"id":"c1","update":"partial data"}',
        '{"type":"turn_done","turn_id":1,"message":"",'
            '"tool_results":[{"id":"c1","name":"read","ok":true,'
            '"text":"data"}],'
            '"usage":{"input":0,"output":0,"cost":0.0},'
            '"stop_reason":"toolUse"}',
        '{"type":"turn_done","turn_id":2,"message":"done","tool_results":[],'
            '"usage":{"input":0,"output":0,"cost":0.0},"stop_reason":"stop"}',
      ]);
    });

    test('summary mode bounds long argument values', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'write',
          args: {'content': 'x' * 5000},
          timestamp: DateTime.utc(2026),
        ),
        CancelTokenSource().token,
      );
      final frame = jsonDecode(out.lines.last) as Map<String, dynamic>;
      expect(frame['args_summary'] as String, hasLength(lessThan(200)));
      expect(frame['args_summary'] as String, contains('content='));
    });

    test('full mode carries the raw JSON arguments', () async {
      final out = _Lines();
      final hep = HepWriter(
        emit: out.emit,
        fahVersion: '9.9.9',
        toolArgs: HepToolArgs.full,
      );
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        ToolExecutionStartEvent(
          toolCallId: 'c1',
          toolName: 'write',
          args: {'content': 'x' * 5000},
          timestamp: DateTime.utc(2026),
        ),
        CancelTokenSource().token,
      );
      final frame = jsonDecode(out.lines.last) as Map<String, dynamic>;
      expect(frame['args_summary'] as String, contains('"content":"xxxx'));
      // Still bounded — lifelong threads must not blow the pipe.
      expect(frame['args_summary'] as String, hasLength(lessThan(4200)));
    });

    test('aborted turn emits cancelled, never turn_done', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
          toolResults: const [],
        ),
        CancelTokenSource().token,
      );
      expect(out.lines.last, '{"type":"cancelled","turn_id":1}');
      expect(
        out.lines.where((l) => l.contains('turn_done')),
        isEmpty,
      );
    });

    test('error turn emits turn_error with fatal=true', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(
            stopReason: StopReason.error,
            errorMessage: 'provider boom',
          ),
          toolResults: const [],
        ),
        CancelTokenSource().token,
      );
      expect(
        out.lines.last,
        '{"type":"turn_error","turn_id":1,"error":"provider boom",'
        '"fatal":true}',
      );
    });

    test('pre-flight compaction frames carry the upcoming turn id', () {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      hep.compactionStart();
      hep.compactionEnd(4200);
      expect(out.lines, [
        '{"type":"compaction_start","turn_id":1}',
        '{"type":"compaction_end","turn_id":1,"tokens_freed":4200}',
      ]);
      // The turn the compaction preceded reuses the id.
      hep.writeHeader(sessionId: 's');
      expect(hep.currentTurnId, 1);
    });

    test('usage rides turn_done from the assistant message', () async {
      final out = _Lines();
      final hep = HepWriter(emit: out.emit, fahVersion: '9.9.9');
      await hep.handleEvent(const AgentStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(const TurnStartEvent(), CancelTokenSource().token);
      await hep.handleEvent(
        TurnEndEvent(
          message: _assistant(
            usage: const Usage(
              input: 100,
              output: 7,
              cacheRead: 3,
              cacheWrite: 0,
              totalTokens: 107,
              cost: UsageCost(input: 0.1, output: 0.2, total: 0.3),
            ),
          ),
          toolResults: const [],
        ),
        CancelTokenSource().token,
      );
      expect(
        out.lines.last,
        contains('"usage":{"input":100,"output":7,"cost":0.3}'),
      );
    });
  });
}
