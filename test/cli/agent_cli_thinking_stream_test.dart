/// CLI integration tests for the opt-in live thinking stream (gh-1198):
/// line-mode and headless runs print thinking deltas dimmed, in order,
/// before the answer when the run opts in (`output.streamThinking` config
/// or the `--stream-thinking` flag — both resolve to the effective
/// [AgentCliConfig.streamThinking]), the default stays byte-identical
/// (AC3), and with the stream OFF a provider request that produces no
/// events gets the periodic `… reasoning Ns` liveness line on the waiting
/// cadence (AC4).
///
/// gh-1430 extends the family: a request whose events flow but render
/// NOTHING (thinking deltas with the stream off) gets the
/// `… reasoning Ns (streaming)` heartbeat instead of going byte-silent
/// mid-thinking — the window the bench round-4 kills lived in.
library;

import 'dart:async';
import 'dart:convert';

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
    content: [
      ThinkingContent(thinking: thinking),
      TextContent(text: text),
    ],
  );
  return [
    StartEvent(partial: empty),
    ThinkingStartEvent(contentIndex: 0, partial: empty),
    ThinkingDeltaEvent(contentIndex: 0, delta: thinking, partial: withThinking),
    ThinkingEndEvent(contentIndex: 0, content: thinking, partial: withThinking),
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

/// A provider stream that streams its thinking deltas (which headless
/// does not render by default) and then STALLS until [release]: the
/// gh-1430 mid-thinking window — events flow, the pane used to go
/// byte-silent. [pushThinking] streams further deltas while gated (a
/// reasoning burst keeps emitting); the answer streams normally once
/// released.
class GatedThinkingStreamFunction {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  var _deltas = 0;

  /// Streams one more unrendered thinking delta while the burst runs.
  void pushThinking(String delta) {
    _deltas++;
    final partial = testAssistant(
      content: [ThinkingContent(thinking: 'pondering${' more' * _deltas}')],
    );
    _stream?.push(
      ThinkingDeltaEvent(contentIndex: 0, delta: delta, partial: partial),
    );
  }

  AssistantMessageEventStream? _stream;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    _stream = stream;
    final empty = testAssistant();
    final withThinking = testAssistant(
      content: [ThinkingContent(thinking: 'pondering')],
    );
    stream.push(StartEvent(partial: empty));
    stream.push(ThinkingStartEvent(contentIndex: 0, partial: empty));
    stream.push(
      ThinkingDeltaEvent(
        contentIndex: 0,
        delta: 'pondering',
        partial: withThinking,
      ),
    );
    unawaited(
      _gate.future.then((_) {
        final withText = testAssistant(
          content: [
            ThinkingContent(thinking: 'pondering'),
            TextContent(text: 'Answer'),
          ],
        );
        stream.push(
          TextDeltaEvent(contentIndex: 1, delta: 'Answer', partial: withText),
        );
        stream.push(DoneEvent(reason: StopReason.stop, message: withText));
        stream.end();
      }),
    );
    // A real provider closes the stream when the request's CancelToken
    // fires (the abort path depends on it); mirror that so an interrupt
    // mid-burst terminates the run instead of hanging on the gate (the
    // E4 abort-mid-heartbeat IT rides this path).
    unawaited(
      cancelToken?.onCancel.then((_) {
        if (_gate.isCompleted) return;
        stream.push(
          ErrorEvent(
            reason: StopReason.aborted,
            error: testAssistant(
              stopReason: StopReason.aborted,
              errorMessage: 'Operation aborted',
            ),
          ),
        );
        stream.end();
      }),
    );
    return stream;
  }
}

/// A provider stream whose call THROWS before a single event lands —
/// the dead-window terminal path (review thread, gh-1198): the agent
/// loop synthesizes an error turn (`_providerErrorTurn` →
/// `_finishWithoutStream`), whose MessageStart/End events must disarm
/// the reasoning watch instead of leaving it printing `… reasoning Ns`
/// forever over an idle session.
class ThrowingStreamFunction {
  int get calls => _calls;
  int _calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    _calls++;
    throw Exception('provider 500 — stream call exploded');
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
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.ansi),
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
      final cli = cliFor(
        fake.call,
        streamThinking: true,
        useColor: true,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.ansi),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      final dimA = '\x1B[2mthink A\x1B[0m';
      final dimB = '\x1B[2mthink B\x1B[0m';
      expect(out, contains(dimA));
      expect(out, contains(dimB));
      // The answer renders once at message end, on its own line after the
      // first burst (the E1 separation rule).
      expect(out, contains('$dimA\n'));
      expect('part one. part two'.allMatches(out), hasLength(1));
    });

    test('a PURE-THINKING message (no text delta) closes the dimmed '
        'stream line at message end', () async {
      // A tool-call turn that streams only thinking (models that reason
      // before every tool call): the dimmed burst must be newline-closed
      // at message end on the buffered surface, and the state reset so
      // the NEXT turn's thinking/text interleave starts clean (the
      // `_streamedThinking` reset path gh-1198 added).
      final empty = testAssistant();
      final withThinking = testAssistant(
        content: [ThinkingContent(thinking: 'which file')],
      );
      const call = ToolCall(
        id: 't1',
        name: 'bash',
        arguments: {'command': 'ls'},
      );
      final thinkingToolPartial = testAssistant(
        content: [
          ThinkingContent(thinking: 'which file'),
          call,
        ],
        stopReason: StopReason.toolUse,
      );
      final pureThinkingTurn = <AssistantMessageEvent>[
        StartEvent(partial: empty),
        ThinkingDeltaEvent(
          contentIndex: 0,
          delta: 'which file',
          partial: withThinking,
        ),
        ToolCallStartEvent(contentIndex: 1, partial: withThinking),
        ToolCallEndEvent(
          contentIndex: 1,
          toolCall: call,
          partial: thinkingToolPartial,
        ),
        DoneEvent(reason: StopReason.toolUse, message: thinkingToolPartial),
      ];
      final fake = FakeStreamFunction([
        pureThinkingTurn,
        thinkingTurn('done thinking', 'All done'),
      ]);
      final cli = cliFor(
        fake.call,
        streamThinking: true,
        useColor: true,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.ansi),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 2 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      final dim = '\x1B[2mwhich file\x1B[0m';
      expect(out, contains(dim));
      // The pure-thinking turn's dimmed stream line is closed by the
      // end-of-message flush — the burst does not glue onto the next
      // turn's output.
      expect(out, contains('$dim\n'));
      // The next turn streams and renders normally after the reset.
      expect(out, contains('\x1B[2mdone thinking\x1B[0m'));
      expect(out, contains('All done'));
      expect('All done'.allMatches(out), hasLength(1));
    });
  });

  group('AC2: headless -p, flag on', () {
    test('captured stdout carries the dimmed thinking before the answer, '
        'interleaved with the tool card across turns', () async {
      // Turn 1: think → partial answer → a tool call (stopReason toolUse)
      // so the run continues; the tool card prints between the turns.
      final empty = testAssistant();
      final withThinking = testAssistant(
        content: [ThinkingContent(thinking: 'why not')],
      );
      final withText = testAssistant(
        content: [TextContent(text: 'let me check')],
      );
      const call = ToolCall(
        id: 't1',
        name: 'bash',
        arguments: {'command': 'echo hi'},
      );
      final toolPartial = testAssistant(
        content: [
          ThinkingContent(thinking: 'why not'),
          TextContent(text: 'let me check'),
          call,
        ],
        stopReason: StopReason.toolUse,
      );
      final firstTurn = <AssistantMessageEvent>[
        StartEvent(partial: empty),
        ThinkingDeltaEvent(
          contentIndex: 0,
          delta: 'why not',
          partial: withThinking,
        ),
        TextDeltaEvent(
          contentIndex: 1,
          delta: 'let me check',
          partial: withText,
        ),
        ToolCallStartEvent(contentIndex: 2, partial: withText),
        ToolCallEndEvent(contentIndex: 2, toolCall: call, partial: toolPartial),
        DoneEvent(reason: StopReason.toolUse, message: toolPartial),
      ];
      final fake = FakeStreamFunction([
        firstTurn,
        thinkingTurn('second thought', 'All done'),
      ]);
      final shell = FakeShell(stdout: 'hi');
      final cliEnv = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: cliEnv,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          streamThinking: true,
        ),
        io: io,
        streamFunction: fake.call,
        useColor: true,
        waitingClock: () => now,
      );
      await cli.runHeadless('hi');

      final out = io.out.toString();
      expect(out, contains('\x1B[2mwhy not\x1B[0m'));
      expect(out, contains('let me check'));
      // The tool card prints between the two thinking bursts.
      expect(out, contains('•'));
      expect(out.indexOf('\x1B[2mwhy not\x1B[0m'), lessThan(out.indexOf('•')));
      expect(
        out.indexOf('•'),
        lessThan(out.indexOf('\x1B[2msecond thought\x1B[0m')),
      );
      expect(out, contains('All done'));
    });
  });

  group('AC3: flag off (default) is byte-identical', () {
    test(
      'line mode styled surface: thinking never reaches the output',
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
      },
    );

    test(
      'headless raw passthrough: unchanged text stream, no thinking',
      () async {
        final fake = FakeStreamFunction([
          thinkingTurn('secret thoughts', 'Seen'),
        ]);
        final cli = cliFor(fake.call);
        await cli.runHeadless('hi');

        final out = io.out.toString();
        expect(out, contains('Seen'));
        expect(out, isNot(contains('secret thoughts')));
      },
    );
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
      // TUI branch's discipline — no per-delta markdown formatting split
      // the delta into many pairs).
      expect(out, contains('\x1B[2m$burst\x1B[0m'));
      expect('\x1B[2m$burst'.allMatches(out), hasLength(1));
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

    test('a normally streaming model produces zero liveness lines', () async {
      final fake = FakeStreamFunction([
        thinkingTurn('some thinking', 'answer'),
      ]);
      final cli = cliFor(fake.call);
      await cli.runHeadless('hi');
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
    });

    test('a provider request that FAILS before its first event disarms '
        'the watch (the error turn is visible progress)', () async {
      // The dead-window terminal path (review pin): the stream call
      // throws before a single event lands, the agent loop synthesizes
      // the error turn (`_providerErrorTurn` → `_finishWithoutStream`
      // emits MessageStart/End), and those events disarm the watch —
      // an idle-after-error session must never keep printing
      // `… reasoning Ns` forever.
      final fake = ThrowingStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      await cli.runHeadless('hi');
      expect(fake.calls, 1);
      expect(cli.reasoningLivenessActiveForTest, isFalse);
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
    });

    test(
      'flag on: the watch never arms — the live stream owns visibility',
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
      },
    );

    test('line mode arms the same watch (same records as headless)', () async {
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

  group('gh-1430: stream liveness heartbeat (flag off)', () {
    // The bare tier-2 line, so assertions can tell the two apart — the
    // `(streaming)` suffix never appears on a tier-2 line.
    final bareReasoningLine = RegExp(r'… reasoning \d+s\n');

    test('AC3: thinking-only deltas keep stdout growing with `… reasoning '
        'Ns (streaming)` heartbeat lines; the tier-2 line stops at the '
        'first event', () async {
      final fake = GatedThinkingStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(
        () => cli.streamLivenessActiveForTest,
        reason: 'the stream heartbeat arms with the request',
      );
      // The first event landed: tier-2 is over, the stream heartbeat is
      // the signal now.
      await waitForIt(
        () => !cli.reasoningLivenessActiveForTest,
        reason: 'tier-2 disarms at the first event',
      );

      // Tick before the threshold: silent.
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));

      now = now.add(const Duration(seconds: 60));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 60s (streaming)'));

      // The burst keeps emitting: a fresh delta re-arms the window and
      // the next tick prints again — the pane grows monotonically.
      fake.pushThinking(' still going');
      await waitForIt(
        () => cli.streamLivenessDirtyForTest,
        reason: 'the pushed delta reached the host and marked the window',
      );
      now = now.add(const Duration(seconds: 60));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 120s (streaming)'));

      // The events flow but render nothing, so the pane kept growing —
      // and no BARE tier-2 line may appear after the first event.
      expect(bareReasoningLine.hasMatch(io.out.toString()), isFalse);

      // The text delta renders: the heartbeat disarms, the run completes.
      fake.release();
      await run;
      final linesBefore = '(streaming)'.allMatches(io.out.toString()).length;
      cli.streamLivenessTickForTest();
      expect(
        '(streaming)'.allMatches(io.out.toString()),
        hasLength(linesBefore),
      );
      expect(cli.streamLivenessActiveForTest, isFalse);
      expect(io.out.toString(), contains('Answer'));
    });

    test('AC2: an event-silent stream stops heartbeating — at most one '
        'more line after the last event, then pane silence', () async {
      final fake = GatedThinkingStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(() => cli.streamLivenessActiveForTest);

      now = now.add(const Duration(seconds: 120));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 120s (streaming)'));

      // No more events arrive (the gate stays shut): every later tick is
      // silent — the heartbeat never masks a real death.
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 60));
        cli.streamLivenessTickForTest();
      }
      expect('(streaming)'.allMatches(io.out.toString()), hasLength(1));

      fake.release();
      await run;
    });

    test('AC2: a request with NO events still heartbeats via tier-2 only '
        '(no `(streaming)` line)', () async {
      final fake = GatedSilentStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(() => cli.reasoningLivenessActiveForTest);

      now = now.add(const Duration(seconds: 60));
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 60s\n'));
      expect(io.out.toString(), isNot(contains('(streaming)')));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('(streaming)')));

      fake.release();
      await run;
    });

    test('AC5: a NON-reasoning stream (text renders immediately) produces '
        'zero heartbeat lines', () async {
      final fake = FakeStreamFunction([
        [
          StartEvent(partial: testAssistant()),
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'plain answer',
            partial: testAssistant(content: [TextContent(text: 'plain')]),
          ),
          DoneEvent(
            reason: StopReason.stop,
            message: testAssistant(content: [TextContent(text: 'plain')]),
          ),
        ],
      ]);
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 1,
          toolLivenessTickSeconds: 1,
        ),
      );
      await cli.runHeadless('hi');
      cli.streamLivenessTickForTest();
      cli.reasoningLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
    });

    test('--stream-thinking: rendered deltas own the signal, no heartbeat '
        '(AC5 output unchanged)', () async {
      final fake = GatedThinkingStreamFunction();
      final cli = cliFor(fake.call, streamThinking: true);
      final run = cli.runHeadless('hi');
      await waitForIt(() => cli.isBusy);
      expect(cli.streamLivenessActiveForTest, isFalse);
      cli.streamLivenessTickForTest();
      now = now.add(const Duration(seconds: 120));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), isNot(contains('… reasoning')));
      fake.release();
      await run;
    });

    test(
      'E2: tool rows disarm the heartbeat; the next request re-arms it',
      () async {
        // Turn 1 streams thinking then a tool call; turn 2 thinks again.
        final empty = testAssistant();
        final withThinking = testAssistant(
          content: [ThinkingContent(thinking: 'why')],
        );
        const call = ToolCall(
          id: 't1',
          name: 'bash',
          arguments: {'command': 'echo hi'},
        );
        final toolPartial = testAssistant(
          content: [
            ThinkingContent(thinking: 'why'),
            call,
          ],
          stopReason: StopReason.toolUse,
        );
        final firstTurn = <AssistantMessageEvent>[
          StartEvent(partial: empty),
          ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'why',
            partial: withThinking,
          ),
          ToolCallStartEvent(contentIndex: 1, partial: withThinking),
          ToolCallEndEvent(
            contentIndex: 1,
            toolCall: call,
            partial: toolPartial,
          ),
          DoneEvent(reason: StopReason.toolUse, message: toolPartial),
        ];
        final fake = FakeStreamFunction([
          firstTurn,
          thinkingTurn('again', 'Done'),
        ]);
        final cli = cliFor(
          fake.call,
          waiting: const WaitingConfig(
            toolLivenessSeconds: 60,
            toolLivenessTickSeconds: 60,
          ),
        );
        final run = cli.runHeadless('hi');
        await waitForIt(() => !cli.isBusy, reason: 'the run completes');
        await run;
        // The run completes too fast to tick mid-flight; the observable is
        // the END state: disarmed, zero lines, byte-identical legacy output.
        expect(cli.streamLivenessActiveForTest, isFalse);
        expect(io.out.toString(), isNot(contains('… reasoning')));
        cli.streamLivenessTickForTest();
        expect(io.out.toString(), isNot(contains('… reasoning')));
      },
    );

    test('line mode arms the same heartbeat (shared code path)', () async {
      final fake = GatedThinkingStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 30,
          toolLivenessTickSeconds: 30,
        ),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => cli.streamLivenessActiveForTest);
      now = now.add(const Duration(seconds: 45));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 45s (streaming)'));
      fake.release();
      io.sendLine('/exit');
      await run;
    });

    test('E3: the compaction window arms the tier-2 reasoning line — no '
        'silent multi-minute summarization span in the pane', () async {
      final fake = FakeStreamFunction([thinkingTurn('some thinking', 'done')]);
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      await cli.runHeadless('hi');

      // No agent events fire inside a compaction pass — the window arms
      // the pre-first-event watch explicitly.
      cli.compactionLivenessStartForTest();
      now = now.add(const Duration(seconds: 60));
      cli.reasoningLivenessTickForTest();
      // The BARE tier-2 line (the `\n` anchor excludes a `(streaming)`
      // line) — the summarizer window reads as plain reasoning silence.
      expect(io.out.toString(), contains('… reasoning 60s\n'));
      expect(io.out.toString(), isNot(contains('(streaming)')));

      // Window over: the watch drops, the idle session stays silent.
      cli.compactionLivenessEndForTest();
      now = now.add(const Duration(seconds: 60));
      cli.reasoningLivenessTickForTest();
      final bare = RegExp(r'… reasoning \d+s\n').allMatches(io.out.toString());
      expect(bare, hasLength(1));
    });

    test('E4: abort mid-heartbeat — the run ends cleanly and no '
        '`(streaming)` line ever prints after the abort', () async {
      final fake = GatedThinkingStreamFunction();
      final cli = cliFor(
        fake.call,
        waiting: const WaitingConfig(
          toolLivenessSeconds: 60,
          toolLivenessTickSeconds: 60,
        ),
      );
      final run = cli.runHeadless('hi');
      await waitForIt(() => cli.streamLivenessActiveForTest);

      now = now.add(const Duration(seconds: 60));
      cli.streamLivenessTickForTest();
      expect(io.out.toString(), contains('… reasoning 60s (streaming)'));

      // Ctrl-C mid-thinking: the run terminates through the abort path
      // (exit 130), whose lifecycle events (MessageEnd/AgentEnd) must
      // stop the heartbeat — the pending timer dies with the run and
      // no line can print over the dead stream or the idle session.
      io.interrupt();
      expect(await run, 130);
      expect(cli.streamLivenessActiveForTest, isFalse);
      expect(cli.reasoningLivenessActiveForTest, isFalse);

      final linesAtAbort = '(streaming)'.allMatches(io.out.toString()).length;
      now = now.add(const Duration(seconds: 180));
      cli.streamLivenessTickForTest();
      cli.reasoningLivenessTickForTest();
      expect(
        '(streaming)'.allMatches(io.out.toString()),
        hasLength(linesAtAbort),
      );
    });

    test('E5: stream-json mode — stdout stays structured, the heartbeat '
        'rides stderr, the FIRST-line contract is unchanged', () async {
      final split = SplitChannelCliIO();
      final fake = GatedThinkingStreamFunction();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          streamThinking: false,
          waiting: const WaitingConfig(
            toolLivenessSeconds: 60,
            toolLivenessTickSeconds: 60,
          ),
        ),
        io: split,
        streamFunction: fake.call,
        waitingClock: () => now,
      );
      final frames = <String>[];
      final run = cli.runHeadless(
        'hi',
        streamJson: StreamJsonWriter(emit: frames.add),
      );
      await waitForIt(
        () => cli.streamLivenessActiveForTest,
        reason: 'the stream heartbeat arms with the request',
      );
      now = now.add(const Duration(seconds: 60));
      cli.streamLivenessTickForTest();

      // The FIRST stdout line is the stream-json session header — no
      // heartbeat line ever raced it (the header-race pin).
      expect(frames, isNotEmpty);
      expect(
        (jsonDecode(frames.first) as Map<String, dynamic>)['type'],
        'session',
      );
      // Every stdout line still parses as one JSON object — no prose.
      for (final line in frames) {
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
      // The heartbeat rode the stderr channel: `diag` in the split
      // fixture, never the prose stdout, never the structured frames.
      expect(split.diag.toString(), contains('… reasoning 60s (streaming)'));
      expect(split.out.toString(), isNot(contains('(streaming)')));
      expect(frames.join('\n'), isNot(contains('(streaming)')));

      fake.release();
      expect(await run, 0);
    });

    test('E5: HEP events mode — stdout stays the frame stream, the '
        'heartbeat rides stderr, hep_header stays FIRST', () async {
      final split = SplitChannelCliIO();
      final fake = GatedThinkingStreamFunction();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          streamThinking: false,
          waiting: const WaitingConfig(
            toolLivenessSeconds: 60,
            toolLivenessTickSeconds: 60,
          ),
        ),
        io: split,
        streamFunction: fake.call,
        waitingClock: () => now,
      );
      final frames = <String>[];
      final run = cli.runHeadless(
        'hi',
        hep: HepWriter(emit: frames.add, fahVersion: 'test'),
      );
      await waitForIt(
        () => cli.streamLivenessActiveForTest,
        reason: 'the stream heartbeat arms with the request',
      );
      now = now.add(const Duration(seconds: 60));
      cli.streamLivenessTickForTest();

      expect(frames, isNotEmpty);
      final first = jsonDecode(frames.first) as Map<String, dynamic>;
      expect(first['type'], 'hep_header');
      expect(first['hep'], 'v1');
      for (final line in frames) {
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
      expect(split.diag.toString(), contains('… reasoning 60s (streaming)'));
      expect(frames.join('\n'), isNot(contains('(streaming)')));

      fake.release();
      expect(await run, 0);
    });
  });

  group('reasoningLivenessLine', () {
    test('the pinned grep-friendly format', () {
      expect(reasoningLivenessLine(60), '… reasoning 60s');
      expect(reasoningLivenessLine(125), '… reasoning 125s');
    });
  });
}
