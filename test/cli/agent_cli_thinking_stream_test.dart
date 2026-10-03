/// CLI integration tests for the opt-in live thinking stream (gh-1198):
/// line-mode and headless runs print thinking deltas dimmed, in order,
/// before the answer when the run opts in (`output.streamThinking` config
/// or the `--stream-thinking` flag — both resolve to the effective
/// [AgentCliConfig.streamThinking]), the default stays byte-identical
/// (AC3), and with the stream OFF a provider request that produces no
/// events gets the periodic `… reasoning Ns` liveness line on the waiting
/// cadence (AC4).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/reasoning_liveness.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A reasoning-model turn: thinking deltas land first, then the answer.
List<AssistantMessageEvent> thinkingTurn(String thinking, String text) {
  final empty = testAssistant();
  final withThinking = testAssistant(
    content: [ThinkingContent(thinking: thinking)],
  );
  final partial = testAssistant(
    content: [ThinkingContent(thinking: thinking), TextContent(text: text)],
  );
  return [
    StartEvent(partial: empty),
    ThinkingStartEvent(contentIndex: 0, partial: empty),
    ThinkingDeltaEvent(contentIndex: 0, delta: thinking, partial: withThinking),
    ThinkingEndEvent(
      contentIndex: 0,
      content: thinking,
      partial: withThinking,
    ),
    TextStartEvent(contentIndex: 1, partial: withThinking),
    TextDeltaEvent(contentIndex: 1, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A provider stream that emits NOTHING — not even the start event —
/// until [release]: the dead window AC4's liveness line covers. The
/// answer streams normally once released.
class GatedSilentStreamFunction {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    unawaited(
      _gate.future.then((_) {
        final empty = testAssistant();
        final partial = testAssistant(content: [TextContent(text: 'answered')]);
        stream.push(StartEvent(partial: empty));
        stream.push(
          TextDeltaEvent(contentIndex: 0, delta: 'answered', partial: partial),
        );
        stream.push(DoneEvent(reason: StopReason.stop, message: partial));
        stream.end();
      }),
    );
    return stream;
  }
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  var now = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    now = DateTime.utc(2026, 1, 1, 12);
  });
  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction fake, {
    bool streamThinking = false,
    bool useColor = false,
    MarkdownSurface? markdownSurface,
    bool useTui = false,
    WaitingConfig waiting = const WaitingConfig(),
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      streamThinking: streamThinking,
      waiting: waiting,
    ),
    io: io,
    streamFunction: fake,
    useColor: useColor,
    useTui: useTui,
    markdownSurface: markdownSurface,
    waitingClock: () => now,
  );

  group('AC1: line mode, flag on', () {
    test('thinking deltas print dimmed, in order, before the answer; '
        'the answer still renders once at message end (#774)', () async {
      final fake = FakeStreamFunction([thinkingTurn('pondering…', 'Answer')]);
      // Styled surface (the #774 buffered-answer branch) + color so the
      // dim SGR is observable.
      final cli = cliFor(
        fake.call,
        streamThinking: true,
        useColor: true,
        markdownSurface: const MarkdownSurface(
          mode: MarkdownSurfaceMode.ansi,
        ),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      final dimmedThinking = '\x1B[2mpondering…\x1B[0m';
      expect(out, contains(dimmedThinking));
      // Order: the dimmed thinking lands before the rendered answer.
      expect(out.indexOf(dimmedThinking), lessThan(out.indexOf('Answer')));
      // E1: the streamed thinking and the answer live on separate lines —
      // the answer does not glue onto the dimmed thinking fragment.
      expect(out.contains('$dimmedThinking Answer'), isFalse);
      // The answer renders once at message end (no live text deltas).
      expect('Answer'.allMatches(out), hasLength(1));
    });

    test('mixed interleave (E1): each burst dims around the buffered '
        'answer', () async {
      final empty = testAssistant();
      final events = <AssistantMessageEvent>[
        StartEvent(partial: empty),
        ThinkingDeltaEvent(
          contentIndex: 0,
          delta: 'think A',
          partial: testAssistant(
            content: [ThinkingContent(thinking: 'think A')],
          ),
        ),
        TextDeltaEvent(
          contentIndex: 1,
          delta: 'part one. ',
          partial: testAssistant(content: [TextContent(text: 'part one. ')]),
        ),
        ThinkingDeltaEvent(
          contentIndex: 2,
          delta: 'think B',
          partial: testAssistant(
            content: [
              TextContent(text: 'part one. '),
              ThinkingContent(thinking: 'think B'),
            ],
          ),
        ),
        TextDeltaEvent(
          contentIndex: 3,
          delta: 'part two',
          partial: testAssistant(
            content: [TextContent(text: 'part one. part two')],
          ),
        ),
        DoneEvent(
          reason: StopReason.stop,
          message: testAssistant(
            content: [TextContent(text: 'part one. part two')],
          ),
        ),
      ];
      final fake = FakeStreamFunction([events]);
      final cli = cliFor(fake.call, streamThinking: true, useColor: true);
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('\x1B[2mthink A\x1B[0m'));
      expect(out, contains('\x1B[2mthink B\x1B[0m'));
      expect(out, contains('part one. part two'));
    });
  });

  group('AC2: headless -p, flag on', () {
    test('captured stdout carries the dimmed thinking before the answer, '
        'interleaved with the tool card across turns', () async {
      final toolCalls = [
        const ToolCall(
          id: 't1',
          name: 'bash',
          arguments: {'command': 'echo hi'},
        ),
      ];
      final fake = FakeStreamFunction([
        thinkingTurn('why not', 'let me check'),
        toolTurn(toolCalls),
        thinkingTurn('second thought', 'All done'),
      ]);
      final cli = cliFor(fake.call, streamThinking: true, useColor: true);
      await cli.runHeadless('hi');

      final out = io.out.toString();
      expect(out, contains('\x1B[2mwhy not\x1B[0m'));
      expect(out, contains('let me check'));
      // The tool card still prints between the two thinking turns.
      expect(out, contains('•'));
      expect(
        out.indexOf('\x1B[2mwhy not\x1B[0m'),
        lessThan(out.indexOf('•')),
      );
      expect(
        out.indexOf('•'),
        lessThan(out.indexOf('\x1B[2msecond thought\x1B[0m')),
      );
      expect(out, contains('All done'));
    });
  });

  group('AC3: flag off (default) is byte-identical', () {
    test('line mode styled surface: thinking never reaches the output',
        () async {
      final fake = FakeStreamFunction([
        thinkingTurn('secret thoughts', 'Seen'),
      ]);
      final cli = cliFor(
        fake.call,
        useColor: true,
        markdownSurface: const MarkdownSurface(
          mode: MarkdownSurfaceMode.ansi,
        ),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('Seen'));
      expect(out, isNot(contains('secret thoughts')));
      expect(out, isNot(contains('\x1B[2msecret')));
    });

    test('headless raw passthrough: unchanged text stream, no thinking',
        () async {
      final fake = FakeStreamFunction([
        thinkingTurn('secret thoughts', 'Seen'),
      ]);
      final cli = cliFor(fake.call);
      await cli.runHeadless('hi');

      final out = io.out.toString();
      expect(out, contains('Seen'));
      expect(out, isNot(contains('secret thoughts')));
    });
  });

  group('AC5: SGR discipline', () {
    test('a 10KB single-delta burst dims verbatim — one SGR pair, no '
        'per-delta markdown', () async {
      const burstLength = 10 * 1024;
      final burst = 'x' * burstLength;
      final fake = FakeStreamFunction([thinkingTurn(burst, 'done')]);
      final cli = cliFor(fake.call, streamThinking: true, useColor: true);
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      // The whole burst rides exactly one dim SGR pair (verbatim dim, the
      // TUI branch's discipline — no per-delta markdown formatting).
      expect(out, contains('\x1B[2m$burst\x1B[0m'));
      expect('\x1B[2m'.allMatches(out), hasLength(1));
    });
  });

  group('AC4: reasoning liveness (flag off)', () {
    test('a silent stream prints the periodic `… reasoning Ns` line on '
        'the waiting cadence and stops at the first event', () async {
      final fake = GatedSilentStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.reasoningLivenessActiveForTest,
        reason: 'the reasoning watch arms when the request goes out',
      );

      // Before the threshold: silent.
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));

      // Past the threshold the line fires, then repeats at the cadence.
      now = now.add(const Duration(seconds: 60));
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 60s'));

      now = now.add(const Duration(seconds: 60));
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 120s'));

      // The first event lands: the watch stops — no further lines.
      fake.release();
      await run;
      final linesBefore = '… reasoning'.allMatches(io.out.toString()).length;
      cli.reasoningLivenessTickForTest();
      expect(
        '… reasoning'.allMatches(io.out.toString()),
        hasLength(linesBefore),
      );
      expect(cli.reasoningLivenessActiveForTest, isFalse);
    });

    test('a normally streaming model produces zero liveness lines',
        () async {
      final fake = FakeStreamFunction([
        thinkingTurn('some thinking', 'answer'),
      ]);
      final cli = cliFor(fake.call);
      await cli.runHeadless('hi');
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
    });

    test('flag on: the watch never arms — the live stream owns visibility',
        () async {
      final fake = GatedSilentStreamFunction();
      final cli = cliFor(fake.call, streamThinking: true);
      final run = cli.runHeadless('hi');
      await waitForIt(() => cli.isBusy, reason: 'the run started');
      await waitForIt(
        () => !cli.reasoningLivenessActiveForTest,
        reason: 'the watch stays out while the flag streams thinking',
      );
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
      fake.release();
      await run;
    });

    test('line mode arms the same watch (same records as headless)',
        () async {
      final fake = GatedSilentStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 30,
          toolLivenessTickSeconds: 30,
        ),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(
        () => cli.reasoningLivenessActiveForTest,
        reason: 'the watch arms in line mode too',
      );
      now = now.add(const Duration(seconds: 45));
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 45s'));
      fake.release();
      io.sendLine('/exit');
      await run;
    });
  });

  group('reasoningLivenessLine', () {
    test('the pinned grep-friendly format', () {
      expect(reasoningLivenessLine(60), '… reasoning 60s');
      expect(reasoningLivenessLine(125), '… reasoning 125s');
    });
  });
}
