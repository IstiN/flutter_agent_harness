// In-process wire adapter (toWire/fromWire) — AC3-partial: a scripted run
// emits the golden-identical frame sequence, and NDJSON lines decode back
// to the same ordered event stream (issue #1101 slice 1).
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:flutter_agent_harness/src/wire/wire_adapter.dart';
import 'package:flutter_agent_harness/src/wire/wire_protocol.dart';
import 'package:test/test.dart';

import 'golden_fixtures.dart';

/// The scripted reference run: one event of every non-update kind plus the
/// text-delta update, built from the same native events the goldens pin —
/// so the emitted frame sequence must be golden-identical, frame for frame.
List<AgentEvent> scriptedRun() => [
  nativeEventFor('agent_start'),
  nativeEventFor('turn_start'),
  nativeEventFor('message_start'),
  nativeMessageUpdateFor('message_update_text_delta'),
  nativeEventFor('message_end'),
  nativeEventFor('tool_execution_start'),
  nativeEventFor('tool_execution_update'),
  nativeEventFor('tool_execution_end'),
  nativeEventFor('model_request'),
  nativeEventFor('tool_pairing_repair'),
  nativeEventFor('turn_end'),
  nativeEventFor('agent_end'),
  nativeEventFor('agent_settled'),
];

void main() {
  final eventFixtures = loadGoldenFixtures(eventFixturesDir);

  GoldenFixture fixtureForKind(String kind) =>
      eventFixtures.firstWhere((f) => f.kind == kind);

  /// The message_update variant a scripted event pins: the nested provider
  /// event kind decides which message_update_*.json fixture applies.
  GoldenFixture fixtureForUpdate(AgentEvent event) {
    final nested = (event as MessageUpdateEvent).assistantMessageEvent;
    final variant = switch (nested) {
      TextDeltaEvent() => 'text_delta',
      ThinkingDeltaEvent() => 'thinking_delta',
      ToolCallDeltaEvent() => 'tool_call_delta',
      ToolCallEndEvent() => 'tool_call_end',
      DoneEvent() => 'done',
      ErrorEvent() => 'error',
      _ => throw StateError('No fixture variant for ${nested.runtimeType}'),
    };
    return eventFixtures.firstWhere(
      (f) => f.path.endsWith('message_update_$variant.json'),
    );
  }

  group('AC3-partial: in-process transport parity', () {
    test('scripted run emits the golden-identical frame sequence', () async {
      final protocol = AgentWireProtocol();
      final events = Stream<AgentEvent>.fromIterable(scriptedRun());
      final frames = await toWire(events, protocol: protocol).toList();

      expect(frames, hasLength(scriptedRun().length));
      for (var i = 0; i < frames.length; i++) {
        final event = scriptedRun()[i];
        final golden = event is MessageUpdateEvent
            ? fixtureForUpdate(event)
            : fixtureForKind(_kindOf(event));
        expect(
          frames[i],
          golden.frame,
          reason: 'frame $i (${frames[i]['kind']})',
        );
      }
    });

    test('every fixture kind survives toWire with its golden frame', () async {
      final protocol = AgentWireProtocol();
      for (final fixture in eventFixtures) {
        if (fixture.kind == 'unknown_event') continue;
        if (serverEventKinds.contains(fixture.kind)) {
          // Server-emitted kinds (fa wire-serve, #1103) have no native
          // engine event to push through toWire.
          continue;
        }
        final fileName = fixture.path.split('/').last.replaceAll('.json', '');
        final AgentEvent native;
        if (fixture.kind == 'message_update') {
          native = nativeMessageUpdateFor(fileName);
        } else if (requestEventKinds.contains(fixture.kind)) {
          // Request frames are pinned in the protocol test round-trip.
          continue;
        } else {
          native = nativeEventFor(fixture.kind);
        }
        final frames = await toWire(
          Stream<AgentEvent>.value(native),
          protocol: protocol,
        ).toList();
        expect(frames, hasLength(1), reason: fileName);
        expect(frames.single, fixture.frame, reason: fileName);
      }
    });

    test('NDJSON lines of the scripted run decode back in order', () async {
      final protocol = AgentWireProtocol();
      final events = Stream<AgentEvent>.fromIterable(scriptedRun());
      final frameList = await toWire(events, protocol: protocol).toList();
      final ndjson = frameList.map(AgentWireProtocol.frameLine).join();

      final lines = ndjson.split('\n')..removeWhere((l) => l.isEmpty);
      expect(lines, hasLength(scriptedRun().length));

      final decoded = fromWire(
        Stream<Map<String, dynamic>>.fromIterable(
          lines.map((l) => AgentWireProtocol.parseLine(l)!),
        ),
        protocol: protocol,
      ).toList();

      final results = await decoded;
      expect(results, hasLength(scriptedRun().length));
      for (var i = 0; i < results.length; i++) {
        final result = results[i];
        expect(result, isA<KnownWireEvent>(), reason: 'line $i');
        expect(
          _kindOf((result as KnownWireEvent).event),
          _kindOf(scriptedRun()[i]),
          reason: 'line $i',
        );
      }
    });

    test('fromWire keeps the stream alive across unknown frames', () async {
      final protocol = AgentWireProtocol();
      final frames = <Map<String, dynamic>>[
        {'v': 1, 'kind': 'agent_start'},
        {
          'v': 1,
          'kind': 'brand_new_kind',
          'payload': {'x': 1},
        },
        fixtureForKind('agent_settled').frame,
      ];
      final results = await fromWire(
        Stream<Map<String, dynamic>>.fromIterable(frames),
        protocol: protocol,
      ).toList();

      expect(results, hasLength(3));
      expect(results[0], isA<KnownWireEvent>());
      expect(results[1], isA<UnknownWireEvent>());
      expect((results[1] as UnknownWireEvent).kind, 'brand_new_kind');
      expect(results[2], isA<KnownWireEvent>());
    });
  });
}

/// The wire kind of a native event (mirrors the protocol mapping names).
String _kindOf(AgentEvent event) => switch (event) {
  AgentStartEvent() => 'agent_start',
  AgentEndEvent() => 'agent_end',
  AgentSettledEvent() => 'agent_settled',
  TurnStartEvent() => 'turn_start',
  TurnEndEvent() => 'turn_end',
  MessageStartEvent() => 'message_start',
  MessageUpdateEvent() => 'message_update',
  MessageEndEvent() => 'message_end',
  ToolExecutionStartEvent() => 'tool_execution_start',
  ToolExecutionUpdateEvent() => 'tool_execution_update',
  ToolExecutionEndEvent() => 'tool_execution_end',
  ModelRequestEvent() => 'model_request',
  ToolPairingRepairEvent() => 'tool_pairing_repair',
};
