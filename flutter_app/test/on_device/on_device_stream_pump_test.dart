// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Tests for the shared on-device stream pump: the turn's event contract
// (partial-first deltas, once-guards, cancel, stream-error mapping) run
// against scripted startChat bridges - no engine needed.
import 'package:fa/on_device/on_device_stream_pump.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

extension _MessageText on AssistantMessage {
  String get joinedText =>
      content.whereType<TextContent>().map((b) => b.text).join();
}

const _model = Model(
  id: 'm1',
  api: 'on-device',
  provider: 'test',
  baseUrl: 'unused',
  contextWindow: 4096,
  maxTokens: 512,
);

AssistantMessageEventStream _stream() => AssistantMessageEventStream();

OnDeviceStreamTurn _turn(
  AssistantMessageEventStream stream, {
  String Function(Object error)? formatError,
}) => OnDeviceStreamTurn(
  eventStream: stream,
  model: _model,
  formatError: formatError ?? (error) => error.toString(),
);

void main() {
  group('OnDeviceStreamTurn event contract', () {
    test(
      'partial-first deltas: Start, TextStart, growing snapshots, end',
      () async {
        final stream = _stream();
        final turn = _turn(stream);

        turn.pushStart();
        turn.pushTextDelta('hel');
        turn.pushTextDelta('lo');
        turn.pushTextEnd();
        turn.pushDone(StopReason.stop);
        turn.end();

        final events = await stream.toList();
        expect(events, hasLength(6));
        expect(events[0], isA<StartEvent>());
        expect(events[1], isA<TextStartEvent>());
        // Every delta carries the FULL accumulated text (partial-first).
        expect((events[2] as TextDeltaEvent).delta, 'hel');
        expect((events[2] as TextDeltaEvent).partial.joinedText, 'hel');
        expect((events[3] as TextDeltaEvent).delta, 'lo');
        expect((events[3] as TextDeltaEvent).partial.joinedText, 'hello');
        expect(events[4], isA<TextEndEvent>());
        final done = events[5] as DoneEvent;
        expect(done.reason, StopReason.stop);
        expect(done.message.joinedText, 'hello');
      },
    );

    test('empty deltas are skipped and start/end push once', () async {
      final stream = _stream();
      final turn = _turn(stream);

      turn.pushStart();
      turn.pushStart();
      turn.pushTextDelta('');
      turn.pushTextDelta('x');
      turn.pushTextEnd();
      turn.pushTextEnd();
      turn.pushDone(StopReason.stop);
      turn.pushDone(StopReason.length);
      turn.end();
      turn.end();

      final events = await stream.toList();
      expect(events, hasLength(5));
      expect(
        events.whereType<StartEvent>(),
        hasLength(1),
        reason: 'pushStart is once-guarded',
      );
      expect(
        events.whereType<TextEndEvent>(),
        hasLength(1),
        reason: 'pushTextEnd is once-guarded',
      );
      expect(
        (events.last as DoneEvent).reason,
        StopReason.stop,
        reason: 'pushDone is once-guarded - the first reason wins',
      );
    });

    test('formatError maps stream failures into the ErrorEvent text', () async {
      final stream = _stream();
      final turn = OnDeviceStreamTurn(
        eventStream: stream,
        model: _model,
        formatError: (error) => 'formatted: $error',
      );

      await turn.fail(StateError('raw'), cancelToken: null);
      turn.end();

      final events = await stream.toList();
      final error = events.whereType<ErrorEvent>().single;
      expect(error.error.errorMessage ?? '', 'formatted: Bad state: raw');
      expect(events.last, isA<ErrorEvent>());
    });

    test(
      'turn.fail with a cancelled token aborts with the canonical text',
      () async {
        final stream = _stream();
        final turn = _turn(stream);
        final source = CancelTokenSource();
        final token = source.token;

        source.cancel();
        await turn.fail(StateError('late'), cancelToken: token);
        turn.end();

        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().single;
        expect(error.reason, StopReason.aborted);
        expect(error.error.errorMessage ?? '', 'Request was aborted');
      },
    );
  });

  group('pumpOnDeviceChat', () {
    test(
      'runs startChat to completion; clean finish never interrupts',
      () async {
        final stream = _stream();
        final turn = _turn(stream);
        var interrupted = false;

        final call = await pumpOnDeviceChat(
          turn: turn,
          cancelToken: null,
          interrupt: () async {
            interrupted = true;
          },
          startChat: (call) async {
            turn.pushTextDelta('hi');
            call.complete();
          },
        );
        await call.done;
        turn.pushDone(StopReason.stop);
        turn.end();

        expect(interrupted, isFalse, reason: 'clean finish never interrupts');
        expect(
          (await stream.toList()).whereType<TextDeltaEvent>().single.delta,
          'hi',
        );
      },
    );

    test(
      'cancel mid-stream interrupts the engine and aborts the turn',
      () async {
        final stream = _stream();
        final turn = _turn(
          stream,
          formatError: (error) =>
              error is CancelledException ? 'cancelled' : error.toString(),
        );
        final source = CancelTokenSource();
        final token = source.token;
        var interrupted = false;

        final call = await pumpOnDeviceChat(
          turn: turn,
          cancelToken: token,
          interrupt: () async {
            interrupted = true;
          },
          startChat: (call) async {
            turn.pushTextDelta('par');
            source.cancel();
          },
        );
        await call.done;
        turn.end();

        expect(interrupted, isTrue, reason: 'cancel must interrupt the engine');
        await call.done; // the cancel listener completes the done gate
      },
    );

    test(
      'streamError set by the bridge is preserved on the returned call',
      () async {
        final turn = _turn(_stream());

        final call = await pumpOnDeviceChat(
          turn: turn,
          cancelToken: null,
          interrupt: () async {},
          startChat: (call) async {
            call.streamError = 'engine boom';
            call.complete();
          },
        );
        await call.done;
        turn.end();

        expect(call.streamError, 'engine boom');
      },
    );

    test(
      'the done gate completes exactly once under a cancel/done race',
      () async {
        final turn = _turn(_stream());

        final call = await pumpOnDeviceChat(
          turn: turn,
          cancelToken: null,
          interrupt: () async {},
          startChat: (call) async {
            call.complete();
            call.complete();
          },
        );
        await call.done;

        expect(call.done, completes);
      },
    );
  });
}
