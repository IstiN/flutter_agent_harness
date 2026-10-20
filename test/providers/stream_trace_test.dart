// StreamTrace: the per-chunk timing trail (diagnostic). Three marks —
// `net` (raw provider bytes arrived), `emit` (a delta event left the
// provider adapter), `render` (the host wrote it to its live surface) —
// each carrying elapsed-ms, +delta-ms-since-previous-mark, a sequence
// number, and a detail. Answers "streamed x ms, rendered y ms" from the
// log alone.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/providers/stream_trace.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

final class _CollectingSink implements StreamTraceSink {
  final lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);
}

/// Parses one `<elapsed> +<delta> #<seq> <mark> <detail>` body (the pure
/// side, without the io sink's wall-clock prefix).
({int elapsed, int delta, int seq, String mark, String detail}) _parse(
  String line,
) {
  final match = RegExp(
    r'^t=(\d+)ms \+(\d+)ms #(\d+) (\w+)(?: (.*))?$',
  ).firstMatch(line);
  expect(match, isNotNull, reason: 'line format: $line');
  return (
    elapsed: int.parse(match!.group(1)!),
    delta: int.parse(match.group(2)!),
    seq: int.parse(match.group(3)!),
    mark: match.group(4)!,
    detail: match.group(5) ?? '',
  );
}

void main() {
  tearDown(StreamTrace.stop);

  test('marks are dropped silently while no trace is active', () {
    expect(StreamTrace.active, isNull);
    StreamTrace.mark(StreamTraceMark.net, '+10B');
    // No sink, no throw — inactive is the default of every run.
  });

  test('one line per mark with elapsed, +delta, seq, mark, detail', () {
    final sink = _CollectingSink();
    StreamTrace.start(sink);

    StreamTrace.mark(StreamTraceMark.net, '+512B');
    StreamTrace.mark(StreamTraceMark.emit, 'text +34');
    StreamTrace.mark(StreamTraceMark.render, '+34ch');

    expect(sink.lines, hasLength(3));
    final first = _parse(sink.lines[0]);
    expect(first.mark, 'net');
    expect(first.seq, 1);
    expect(first.detail, '+512B');
    final second = _parse(sink.lines[1]);
    expect(second.mark, 'emit');
    expect(second.seq, 2);
    expect(second.detail, 'text +34');
    final third = _parse(sink.lines[2]);
    expect(third.mark, 'render');
    expect(third.detail, '+34ch');
  });

  test('elapsed and delta grow monotonically with real time', () async {
    final sink = _CollectingSink();
    StreamTrace.start(sink);

    StreamTrace.mark(StreamTraceMark.net, '+1B');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    StreamTrace.mark(StreamTraceMark.emit, 'text +1');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    StreamTrace.mark(StreamTraceMark.render, '+1ch');

    final a = _parse(sink.lines[0]);
    final b = _parse(sink.lines[1]);
    final c = _parse(sink.lines[2]);
    expect(a.elapsed, lessThanOrEqualTo(b.elapsed));
    expect(b.elapsed, lessThanOrEqualTo(c.elapsed));
    expect(a.delta, 0);
    expect(b.delta, greaterThan(0));
    expect(c.delta, greaterThan(0));
    // Delta chains: each +delta is the gap since the PREVIOUS mark.
    expect(b.elapsed - a.elapsed, b.delta);
    expect(c.elapsed - b.elapsed, c.delta);
  });

  test('marks after stop are dropped', () {
    final sink = _CollectingSink();
    final trace = StreamTrace.start(sink);
    StreamTrace.stop();
    trace.record(StreamTraceMark.net, '+1B');
    StreamTrace.mark(StreamTraceMark.net, '+1B');
    expect(sink.lines, isEmpty);
  });

  test('stop clears the active trace', () {
    StreamTrace.start(_CollectingSink());
    expect(StreamTrace.active, isNotNull);
    StreamTrace.stop();
    expect(StreamTrace.active, isNull);
  });

  test('starting a second trace replaces the first (one active trace)', () {
    final first = _CollectingSink();
    final second = _CollectingSink();
    StreamTrace.start(first);
    StreamTrace.start(second);
    StreamTrace.mark(StreamTraceMark.net, '+1B');
    expect(first.lines, isEmpty);
    expect(second.lines, hasLength(1));
  });

  test('all three marks are named net, emit, render', () {
    expect(StreamTraceMark.values.map((m) => m.name), [
      'net',
      'emit',
      'render',
    ]);
  });

  group('emit marks fire once per delta — wrapper hops stay silent', () {
    // pr-1727 review IMPORTANT pin: push() is overridden on EVERY
    // AssistantMessageEventStream, including the wrapper streams that
    // re-push inner events (transient-retry, DIAL cache probe,
    // silent-stream policy, fallback, queue, telemetry, prompt tools).
    // Only the adapter's own stream may emit; wrappers construct with
    // traced: false.
    test('a stream constructed with traced: false drops emit marks', () {
      final sink = _CollectingSink();
      StreamTrace.start(sink);

      final silent = AssistantMessageEventStream(traced: false);
      silent
        ..push(
          TextDeltaEvent(
            delta: 'hey',
            contentIndex: 0,
            partial: testAssistant(
              content: const [TextContent(text: 'hey')],
            ),
          ),
        )
        ..push(
          DoneEvent(
            reason: StopReason.stop,
            message: testAssistant(
              content: const [TextContent(text: 'hey')],
            ),
          ),
        )
        ..end();
      expect(sink.lines, isEmpty, reason: 'wrapper hops must not emit');

      final loud = AssistantMessageEventStream();
      loud.push(
        TextDeltaEvent(
          delta: 'hey',
          contentIndex: 0,
          partial: testAssistant(content: const [TextContent(text: 'hey')]),
        ),
      );
      loud.end();
      expect(sink.lines.where((l) => l.contains(' emit ')), hasLength(1));
    });

    test('one emit per delta through transientRetryStreamFunction', () async {
      final sink = _CollectingSink();
      StreamTrace.start(sink);

      final inner = AssistantMessageEventStream();
      final wrapped = transientRetryStreamFunction(
        (model, context, {cancelToken}) => inner,
      );
      final drained = wrapped(
        testModel,
        const Context(messages: []),
      ).forEach((_) {});
      scheduleMicrotask(() {
        inner
          ..push(StartEvent(partial: testAssistant()))
          ..push(
            TextDeltaEvent(
              delta: 'he',
              contentIndex: 0,
              partial: testAssistant(
                content: const [TextContent(text: 'he')],
              ),
            ),
          )
          ..push(
            TextDeltaEvent(
              delta: 'llo',
              contentIndex: 0,
              partial: testAssistant(
                content: const [TextContent(text: 'hello')],
              ),
            ),
          )
          ..push(
            DoneEvent(
              reason: StopReason.stop,
              message: testAssistant(
                content: const [TextContent(text: 'hello')],
              ),
            ),
          )
          ..end();
      });
      await drained.timeout(const Duration(seconds: 30));

      // Without the fix the wrapper's own stream re-emits every delta:
      // 4 text emits and 2 terminals instead of one each.
      final textEmits = sink.lines
          .where((l) => l.contains(' emit ') && l.contains('text +'))
          .toList();
      expect(textEmits, hasLength(2), reason: 'one emit per text delta');
      expect(
        sink.lines.where((l) => l.contains(' emit ') && l.contains('terminal')),
        hasLength(1),
        reason: 'one terminal emit, not one per hop',
      );
    });
  });
}
