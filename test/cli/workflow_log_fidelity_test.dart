/// The workflow-log-fidelity suite (gh-1433): a non-interactive headless
/// `fa -p` log reads back as the full narrative of what the agent did and
/// said — thinking deltas AND assistant text, default-on (the post-hoc
/// log IS the UI).
///
/// Matrix:
/// - UT: the pure face/default resolution (`resolveLogFidelityFace` /
///   `resolveLogFidelity`) — both directions of the seam, flag > env >
///   face (E3).
/// - IT (FakeCliIO + scripted FakeStreamFunction): AC1 (dimmed thinking
///   default-on for headless, silent for interactive), AC2 (text streams
///   live; the buffered-answer path provably not taken), AC3 (positional
///   byte order across a tool call), AC4 (`--no-stream-thinking` legacy
///   silence golden), AC5/E6 (redaction markers, live pipeline), E1
///   (whitespace-only narration paints nothing), E2 (abort mid-thinking).
/// - REG: AC6 (structured stream-json byte pin).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:dart_tui/dart_tui.dart' show WindowSizeMsg;
import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/log_fidelity.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

AgentCli cliFor(
  FakeStreamFunction fake, {
  required FakeCliIO io,
  bool headlessRun = true,
  bool noStreamThinking = false,
  bool streamThinking = false,
  bool useColor = false,
  MarkdownSurface? markdownSurface,
  RedactionPipeline? redactionPipeline,
  Map<String, String> environment = const {},
}) => AgentCli(
  config: AgentCliConfig(
    model: testModel,
    apiKey: '[REDACTED:Sensitive Value]',
    env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell(stdout: 'ok')),
    sessionRoot: '/sessions',
    approvalMode: ApprovalMode.yolo,
    headlessRun: headlessRun,
    streamThinking: streamThinking,
    noStreamThinking: noStreamThinking,
    redactionPipeline: redactionPipeline,
    waiting: const WaitingConfig(toolLivenessSeconds: 3600),
  ),
  io: io,
  useColor: useColor,
  markdownSurface: markdownSurface,
  environment: environment,
  streamFunction: fake.call,
);

/// A reasoning-model tool turn: thinking, then narration, then the call.
/// [narration] streams BEFORE the tool_use block; [trailing] AFTER it —
/// the AC3 positional-fidelity probe.
List<AssistantMessageEvent> narratedToolTurn({
  String thinking = 'pondering…',
  String narration = 'Checking the file now.',
  String trailing = '',
}) {
  const call = ToolCall(
    id: 't1',
    name: 'bash',
    arguments: {'command': 'echo hi'},
  );
  final empty = testAssistant();
  final withThinking = testAssistant(
    content: [ThinkingContent(thinking: thinking)],
  );
  final withNarration = testAssistant(
    content: [
      ThinkingContent(thinking: thinking),
      TextContent(text: narration),
    ],
  );
  final withCall = testAssistant(
    content: [
      ThinkingContent(thinking: thinking),
      TextContent(text: narration),
      call,
    ],
    stopReason: StopReason.toolUse,
  );
  final events = <AssistantMessageEvent>[
    StartEvent(partial: empty),
    ThinkingStartEvent(contentIndex: 0, partial: empty),
    ThinkingDeltaEvent(
      contentIndex: 0,
      delta: thinking,
      partial: withThinking,
    ),
    ThinkingEndEvent(
      contentIndex: 0,
      content: thinking,
      partial: withThinking,
    ),
    TextStartEvent(contentIndex: 1, partial: withThinking),
    TextDeltaEvent(contentIndex: 1, delta: narration, partial: withNarration),
    ToolCallStartEvent(contentIndex: 2, partial: withNarration),
    ToolCallEndEvent(contentIndex: 2, toolCall: call, partial: withCall),
  ];
  if (trailing.isNotEmpty) {
    final withTrailing = testAssistant(
      content: [
        ThinkingContent(thinking: thinking),
        TextContent(text: narration),
        call,
        TextContent(text: trailing),
      ],
      stopReason: StopReason.toolUse,
    );
    events
      ..add(TextStartEvent(contentIndex: 3, partial: withCall))
      ..add(
        TextDeltaEvent(contentIndex: 3, delta: trailing, partial: withTrailing),
      );
  }
  events.add(
    DoneEvent(
      reason: StopReason.toolUse,
      message: events.last.partial,
    ),
  );
  return events;
}

/// A reasoning-model turn: thinking deltas land first, then the answer.
List<AssistantMessageEvent> thinkingOnlyTurn(String thinking, String text) {
  final empty = testAssistant();
  final withThinking = testAssistant(
    content: [ThinkingContent(thinking: thinking)],
  );
  final full = testAssistant(
    content: [
      ThinkingContent(thinking: thinking),
      TextContent(text: text),
    ],
  );
  return [
    StartEvent(partial: empty),
    ThinkingStartEvent(contentIndex: 0, partial: empty),
    ThinkingDeltaEvent(
      contentIndex: 0,
      delta: thinking,
      partial: withThinking,
    ),
    ThinkingEndEvent(
      contentIndex: 0,
      content: thinking,
      partial: withThinking,
    ),
    TextStartEvent(contentIndex: 1, partial: withThinking),
    TextDeltaEvent(contentIndex: 1, delta: text, partial: full),
    DoneEvent(reason: StopReason.stop, message: full),
  ];
}

/// A 2+ tool-call message with narration BETWEEN the calls and after the
/// second one — the AC3 multi-call positional probe: `before` paints
/// live ahead of the calls, `between` holds behind call 1, `after`
/// behind call 2. Each narration segment must flush after ITS OWN
/// call's result row (review PRRT_kwDOTXdlLc6qt-V0).
List<AssistantMessageEvent> multiNarrationToolTurn() {
  const before = 'before the first call';
  const between = 'narration between the calls';
  const after = 'narration after the second call';
  const call1 = ToolCall(
    id: 'mc1',
    name: 'bash',
    arguments: {'command': 'echo one'},
  );
  const call2 = ToolCall(
    id: 'mc2',
    name: 'bash',
    arguments: {'command': 'echo two'},
  );
  AssistantMessage partial(List<ContentBlock> content) => testAssistant(
    content: content,
    stopReason: StopReason.toolUse,
  );
  final p0 = testAssistant();
  final p1 = partial([TextContent(text: before)]);
  final p2 = partial([TextContent(text: before), call1]);
  final p3 = partial([TextContent(text: before), call1, TextContent(text: between)]);
  final p4 = partial([
    TextContent(text: before),
    call1,
    TextContent(text: between),
    call2,
  ]);
  final p5 = partial([
    TextContent(text: before),
    call1,
    TextContent(text: between),
    call2,
    TextContent(text: after),
  ]);
  return [
    StartEvent(partial: p0),
    TextStartEvent(contentIndex: 0, partial: p0),
    TextDeltaEvent(contentIndex: 0, delta: before, partial: p1),
    ToolCallStartEvent(contentIndex: 1, partial: p1),
    ToolCallEndEvent(contentIndex: 1, toolCall: call1, partial: p2),
    TextStartEvent(contentIndex: 2, partial: p2),
    TextDeltaEvent(contentIndex: 2, delta: between, partial: p3),
    ToolCallStartEvent(contentIndex: 3, partial: p3),
    ToolCallEndEvent(contentIndex: 3, toolCall: call2, partial: p4),
    TextStartEvent(contentIndex: 4, partial: p4),
    TextDeltaEvent(contentIndex: 4, delta: after, partial: p5),
    DoneEvent(reason: StopReason.toolUse, message: p5),
  ];
}

/// A text-only stream held open until [release]: the AC2 proof that
/// stdout grows during the stream (the buffered path would print only at
/// message end).
class GatedTextStream {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    final empty = testAssistant();
    final partial = testAssistant(content: [TextContent(text: 'streaming…')]);
    stream.push(StartEvent(partial: empty));
    stream.push(
      TextDeltaEvent(contentIndex: 0, delta: 'streaming…', partial: partial),
    );
    unawaited(
      _gate.future.then((_) {
        stream.push(
          DoneEvent(reason: StopReason.stop, message: partial),
        );
        stream.end();
      }),
    );
    return stream;
  }
}

/// Minimal [FaTuiCallbacks] for the E8 width-seam controller tests.
FaTuiCallbacks _tuiCallbacks() => FaTuiCallbacks(
  onSubmit: (line, {images = const []}) async {},
  onModelSelected: (id) async {},
  buildSlashMenu: (prefix) => const [],
  buildModelMenu: (filter, width) => const [],
  statusLine: () => 'test',
  prompt: 'fa> ',
);

void main() {
  group('UT: face + default resolution', () {
    test('the seam: headless run → log face, REPL → interactive line, '
        'TUI wins over both', () {
      expect(
        resolveLogFidelityFace(useTui: false, headlessRun: true),
        LogFidelityFace.log,
      );
      expect(
        resolveLogFidelityFace(useTui: false, headlessRun: false),
        LogFidelityFace.interactiveLine,
      );
      expect(
        resolveLogFidelityFace(useTui: true, headlessRun: true),
        LogFidelityFace.tui,
      );
    });

    test('AC1: the log face renders thinking by default; interactive '
        'line mode stays at the gh-1198 opt-in', () {
      final log = resolveLogFidelity(
        face: LogFidelityFace.log,
        streamThinkingSetting: false,
      );
      expect(log.streamThinking, isTrue, reason: 'the log IS the UI');
      expect(log.liveText, isTrue, reason: 'never buffer on the log face');
      final line = resolveLogFidelity(
        face: LogFidelityFace.interactiveLine,
        streamThinkingSetting: false,
      );
      expect(line.streamThinking, isFalse, reason: '#1198 byte-pin');
      expect(line.liveText, isFalse);
      final lineOptIn = resolveLogFidelity(
        face: LogFidelityFace.interactiveLine,
        streamThinkingSetting: true,
      );
      expect(lineOptIn.streamThinking, isTrue);
    });

    test('the TUI face is unchanged by every flag and the env', () {
      for (final setting in [false, true]) {
        for (final hatch in [false, true]) {
          final tui = resolveLogFidelity(
            face: LogFidelityFace.tui,
            streamThinkingSetting: setting,
            noStreamThinking: hatch,
            envFidelity: logFidelityLegacyEnvValue,
          );
          expect(tui.streamThinking, isTrue);
          expect(tui.liveText, isTrue);
        }
      }
    });

    test('E3: flag > env > face default', () {
      // The hatch silences the log face's thinking…
      expect(
        resolveLogFidelity(
          face: LogFidelityFace.log,
          streamThinkingSetting: false,
          noStreamThinking: true,
        ).streamThinking,
        isFalse,
      );
      // …and beats a `full` env…
      expect(
        resolveLogFidelity(
          face: LogFidelityFace.log,
          streamThinkingSetting: false,
          noStreamThinking: true,
          envFidelity: 'full',
        ).streamThinking,
        isFalse,
      );
      // …while `legacy` alone reverts the whole face.
      final legacy = resolveLogFidelity(
        face: LogFidelityFace.log,
        streamThinkingSetting: false,
        envFidelity: 'Legacy ',
      );
      expect(legacy.streamThinking, isFalse);
      expect(legacy.liveText, isFalse, reason: 'legacy = the pre-flip face');
      // An unknown value keeps the face defaults (fail-open to fidelity).
      final unknown = resolveLogFidelity(
        face: LogFidelityFace.log,
        streamThinkingSetting: false,
        envFidelity: 'whatever',
      );
      expect(unknown.streamThinking, isTrue);
      expect(unknown.liveText, isTrue);
    });

    test('AC4: the hatch is thinking-scoped — live text stays live', () {
      final log = resolveLogFidelity(
        face: LogFidelityFace.log,
        streamThinkingSetting: false,
        noStreamThinking: true,
      );
      expect(log.liveText, isTrue);
    });
  });

  group('IT: the headless log face renders the full narrative', () {
    late FakeCliIO io;

    setUp(() => io = FakeCliIO());
    tearDown(() => io.close());

    test('AC1: dimmed thinking deltas render with NO flags (headless), '
        'before the answer', () async {
      final fake = FakeStreamFunction([
        narratedToolTurn(),
        textTurn('All done — found it.'),
      ]);
      final cli = cliFor(fake, io: io);
      final exit = await cli.runHeadless('check');
      expect(exit, 0);
      final out = io.out.toString();
      expect(out, contains('pondering…'), reason: out);
      // Order: thinking renders before the narration and the tool row.
      expect(out.indexOf('pondering…'), lessThan(out.indexOf('• bash')));
      expect(out.indexOf('pondering…'), lessThan(out.indexOf('done')));
    });

    test('AC1 (SGR): with a styling host the deltas carry the gh-1198 '
        'dim pair — one pair around the verbatim burst', () async {
      final fake = FakeStreamFunction([thinkingOnlyTurn('pondering…', 'A')]);
      final cli = cliFor(fake, io: io, useColor: true);
      await cli.runHeadless('check');
      final out = io.out.toString();
      expect(out, contains('\x1B[2mpondering…\x1B[0m'), reason: out);
      expect('pondering…'.allMatches(out), hasLength(1));
    });

    test('AC1 (both directions of the seam): the interactive host stays '
        'silent without the flag', () async {
      final fake = FakeStreamFunction([thinkingOnlyTurn('pondering…', 'Answer')]);
      final cli = cliFor(
        fake,
        io: io,
        headlessRun: false,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;
      final out = io.out.toString();
      expect(out.contains('pondering…'), isFalse, reason: out);
      expect(out, contains('Answer'));
    });

    test('AC2: text streams live on the log face — stdout grows BEFORE '
        'the stream ends (the buffered path provably not taken)', () async {
      final gated = GatedTextStream();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(
            cwd: '/work',
            shell: FakeShell(stdout: 'ok'),
          ),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
        ),
        io: io,
        markdownSurface: const MarkdownSurface(
          mode: MarkdownSurfaceMode.ansi,
        ),
        streamFunction: gated.call,
      );
      final run = cli.runHeadless('say');
      // The delta must land while the message is still open: the
      // buffered-answer path would hold every byte until DoneEvent.
      await waitForIt(
        () => io.out.toString().contains('streaming…'),
        reason: 'the text delta must land while the message is still open',
      );
      final midStream = io.out.toString();
      expect(midStream, contains('streaming…'));
      expect(
        midStream.contains('fa-tokens'),
        isFalse,
        reason: 'the message has not ended yet — nothing flushed a render',
      );
      gated.release();
      await run;
    });

    test('AC3: positional byte order — narration BEFORE the tool line, '
        'same-message trailing narration AFTER the result row', () async {
      const trailing = 'and cross-checking the output.';
      final fake = FakeStreamFunction([
        narratedToolTurn(trailing: trailing),
        textTurn('All done — found it.'),
      ]);
      final cli = cliFor(fake, io: io);
      final exit = await cli.runHeadless('check');
      expect(exit, 0);
      final out = io.out.toString();
      final narration = out.indexOf('Checking the file now.');
      final toolStart = out.indexOf('• bash');
      final toolEnd = out.indexOf('✓ bash');
      final trailingAt = out.indexOf(trailing);
      final finalText = out.indexOf('All done — found it.');
      expect(narration, greaterThanOrEqualTo(0));
      expect(toolStart, greaterThan(narration),
          reason: 'narration before the tool line:\n$out');
      expect(toolEnd, greaterThan(toolStart));
      expect(trailingAt, greaterThan(toolEnd),
          reason: 'same-message trailing narration after the RESULT row:\n'
              '$out');
      expect(finalText, greaterThan(toolEnd));
    });

    test('AC3 multi-call: narration follows ITS OWN result row when one '
        'message streams 2+ tool calls', () async {
      final fake = FakeStreamFunction([
        multiNarrationToolTurn(),
        textTurn('All done — found it.'),
      ]);
      final cli = cliFor(fake, io: io);
      final exit = await cli.runHeadless('check');
      expect(exit, 0);
      final out = io.out.toString();
      // Rows are pinned by their distinctive detail (the loop may emit
      // start rows up front and settle the results in completion order).
      // Each narration segment lands after ITS OWN call's result row —
      // never flushed wholesale after the first one.
      final before = out.indexOf('before the first call');
      final result1 = out.indexOf('✓ bash · echo one');
      final result2 = out.indexOf('✓ bash · echo two');
      final between = out.indexOf('narration between the calls');
      final after = out.indexOf('narration after the second call');
      expect(before, greaterThanOrEqualTo(0), reason: out);
      expect(result1, greaterThan(before), reason: out);
      expect(result2, greaterThan(result1), reason: out);
      expect(between, greaterThan(result1),
          reason: 'narration streamed between the calls renders after the '
              'FIRST result row:\n$out');
      expect(between, lessThan(result2),
          reason: '…and before the second result row — positional, not '
              'drifted:\n$out');
      expect(after, greaterThan(result2),
          reason: 'narration streamed after the second call renders after '
              'the SECOND result row, not after the first (the '
              'single-buffer drift):\n$out');
    });

    test('AC3 orphan: post-tool narration survives a result-less turn — '
        'flushed at message end, before the stop summary', () async {
      // A degenerate engine turn: the tool-call block opens, narration
      // streams after it, and the message ends TERMINALLY (StopReason.stop,
      // not toolUse) —
      // no execution follows, the result row never renders. Nothing
      // swallowed: the hold flushes at message end, before the summary.
      final empty = testAssistant();
      final withNarration = testAssistant(
        content: [TextContent(text: 'orphan narration')],
      );
      final events = <AssistantMessageEvent>[
        StartEvent(partial: empty),
        ToolCallStartEvent(contentIndex: 0, partial: empty),
        TextStartEvent(contentIndex: 1, partial: empty),
        TextDeltaEvent(
          contentIndex: 1,
          delta: 'orphan narration',
          partial: withNarration,
        ),
        DoneEvent(reason: StopReason.stop, message: withNarration),
      ];
      final fake = FakeStreamFunction([events]);
      final cli = cliFor(fake, io: io);
      final exit = await cli.runHeadless('go');
      expect(exit, 0);
      final out = io.out.toString();
      final orphanAt = out.indexOf('orphan narration');
      expect(orphanAt, greaterThanOrEqualTo(0),
          reason: 'nothing swallowed:\n$out');
      expect(out.indexOf('fa-tokens:'), greaterThan(orphanAt),
          reason: 'the narration precedes the run summary:\n$out');
    });

    test('E1: whitespace-only narration paints nothing — no stray blank '
        'lines, no separator newlines', () async {
      final fake = FakeStreamFunction([
        narratedToolTurn(narration: '  \n  ', trailing: ''),
        textTurn('done'),
      ]);
      final cli = cliFor(fake, io: io);
      await cli.runHeadless('check');
      final out = io.out.toString();
      expect(out, contains('pondering…'));
      // The thinking closes with ONE newline; the whitespace-only
      // narration must not add another blank line before the tool row.
      final toolRowAt = out.indexOf('• bash');
      expect(toolRowAt, greaterThan(0));
      final before = out.substring(0, toolRowAt);
      expect('\n\n'.allMatches(before), isEmpty,
          reason: 'no stray blank line before the tool row:\n'
              '${before.replaceAll('\x1B', '<ESC>')}');
    });

    test('E2: abort mid-thinking keeps the partial dimmed block and the '
        'banner after it, nothing interleaved', () async {
      final stream = AssistantMessageEventStream();
      final empty = testAssistant();
      final partial = testAssistant(
        content: [ThinkingContent(thinking: 'half a thought')],
      );
      AssistantMessageEventStream abortable(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        stream.push(StartEvent(partial: empty));
        stream.push(
          ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'half a thought',
            partial: partial,
          ),
        );
        cancelToken?.onCancel.then((_) {
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
        });
        return stream;
      }

      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(
            cwd: '/work',
            shell: FakeShell(stdout: 'ok'),
          ),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
          waiting: const WaitingConfig(toolLivenessSeconds: 3600),
        ),
        io: io,
        markdownSurface: const MarkdownSurface(
          mode: MarkdownSurfaceMode.raw,
        ),
        streamFunction: abortable,
      );
      final run = cli.runHeadless('watch');
      await waitForIt(() => io.out.toString().contains('half a thought'));
      io.interrupt();
      await run;
      final out = io.out.toString();
      expect(out, contains('half a thought'));
      // The partial block stays; the banner follows it.
      expect(out.indexOf('aborted'), greaterThan(out.indexOf('half a')));
      // Nothing interleaved: the block is newline-closed before the
      // banner (one newline, no tool rows, no text).
      expect(
        out.indexOf('aborted'),
        greaterThan(out.indexOf('half a thought\n')),
      );
    });

    test('E2 (SGR): with a styling host the partial block keeps its dim '
        'pair and the banner lands after the reset', () async {
      final stream = AssistantMessageEventStream();
      final empty = testAssistant();
      final partial = testAssistant(
        content: [ThinkingContent(thinking: 'half a thought')],
      );
      AssistantMessageEventStream abortable(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        stream.push(StartEvent(partial: empty));
        stream.push(
          ThinkingDeltaEvent(
            contentIndex: 0,
            delta: 'half a thought',
            partial: partial,
          ),
        );
        cancelToken?.onCancel.then((_) {
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
        });
        return stream;
      }

      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(
            cwd: '/work',
            shell: FakeShell(stdout: 'ok'),
          ),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
          waiting: const WaitingConfig(toolLivenessSeconds: 3600),
        ),
        io: io,
        useColor: true,
        markdownSurface: const MarkdownSurface(
          mode: MarkdownSurfaceMode.raw,
        ),
        streamFunction: abortable,
      );
      final run = cli.runHeadless('watch');
      await waitForIt(() => io.out.toString().contains('half a thought'));
      io.interrupt();
      await run;
      final out = io.out.toString();
      expect(out, contains('\x1B[2mhalf a thought'));
      expect(
        out.indexOf('aborted'),
        greaterThan(out.lastIndexOf('\x1B[0m')),
      );
    });
  });

  group('IT: AC4 — the escape hatch restores legacy silence', () {
    late FakeCliIO io;

    setUp(() => io = FakeCliIO());
    tearDown(() => io.close());

    test('REG golden: --no-stream-thinking on a non-interactive host — '
        'tools + answer text only, zero thinking bytes, zero dim SGR',
        () async {
      final fake = FakeStreamFunction([
        narratedToolTurn(),
        textTurn('All done — found it.'),
      ]);
      final cli = cliFor(fake, io: io, noStreamThinking: true);
      final exit = await cli.runHeadless('check');
      expect(exit, 0);
      final out = io.out.toString();
      expect(out.contains('pondering'), isFalse, reason: out);
      expect(out.contains('\x1B[2m'), isFalse, reason: out);
      // The legacy shape still carries the tool activity and the answer.
      expect(out, contains('• bash'));
      expect(out, contains('All done — found it.'));
    });

    test('the hatch re-arms the reasoning liveness gate (the legacy '
        'visibility channel owns the silent window again)', () async {
      // The gate is the SAME resolution the render gate reads: with the
      // hatch on, the log face stops streaming thinking, so the silent
      // window is watched again. The cadence itself is pinned by the
      // gh-1198 suite.
      final fidelity = resolveLogFidelity(
        face: LogFidelityFace.log,
        streamThinkingSetting: false,
        noStreamThinking: true,
      );
      expect(fidelity.streamThinking, isFalse);
      // And without the hatch the log face streams — the watch stays out.
      expect(
        resolveLogFidelity(
          face: LogFidelityFace.log,
          streamThinkingSetting: false,
        ).streamThinking,
        isTrue,
      );
    });
  });

  group('IT: AC5/E6 — redaction of rendered deltas', () {
    late FakeCliIO io;

    setUp(() => io = FakeCliIO());
    tearDown(() => io.close());

    RedactionPipeline pipeline(List<String> secrets) => RedactionPipeline(
      registeredSecrets: secrets,
      config: const RedactionConfig(enabled: true),
    );

    test('AC5: rendered thinking carries [REDACTED:*]; zero raw secret '
        'bytes in the capture', () async {
      const secret = 'super-secret-token-value';
      final fake = FakeStreamFunction([
        narratedToolTurn(
          thinking: 'the token is $secret — do not print it',
          narration: 'checked',
        ),
        textTurn('done'),
      ]);
      final cli = cliFor(fake, io: io, redactionPipeline: pipeline([secret]));
      await cli.runHeadless('check');
      final out = io.out.toString();
      expect(out.contains('[REDACTED:'), isTrue, reason: out);
      expect(out.contains(secret), isFalse,
          reason: 'raw secret leaked:\n$out');
    });

    test('E6: the LIVE pipeline decides at render time — a secret '
        'registered mid-stream is masked in the next delta', () async {
      const early = 'early-registered-secret';
      const late = 'late-registered-secret';
      final redaction = pipeline([early]);
      final stream = AssistantMessageEventStream();
      final empty = testAssistant();
      final d1 = testAssistant(
        content: [ThinkingContent(thinking: 'a $early')],
      );
      final d2 = testAssistant(
        content: [ThinkingContent(thinking: 'a $early b $late')],
      );
      AssistantMessageEventStream redactable(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        stream.push(StartEvent(partial: empty));
        stream.push(
          ThinkingDeltaEvent(contentIndex: 0, delta: 'a $early', partial: d1),
        );
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
            // Mid-run registration (live-mutable config): the NEXT
            // rendered delta must follow the config AT RENDER TIME.
            redaction.registerSecret(late);
            stream.push(
              ThinkingDeltaEvent(
                contentIndex: 0,
                delta: ' b $late',
                partial: d2,
              ),
            );
            stream.push(
              DoneEvent(reason: StopReason.stop, message: d2),
            );
            stream.end();
          }),
        );
        return stream;
      }

      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell(stdout: 'ok')),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
          redactionPipeline: redaction,
        ),
        io: io,
        streamFunction: redactable,
      );
      await cli.runHeadless('check');
      final out = io.out.toString();
      expect(out.contains('[REDACTED:'), isTrue, reason: out);
      expect(out.contains(early), isFalse, reason: out);
      expect(out.contains(late), isFalse,
          reason: 'mid-run secret leaked:\n$out');
    });
  });

  group('IT: E4 — compaction has no silent windows on the log face', () {
    late FakeCliIO io;

    setUp(() => io = FakeCliIO());
    tearDown(() => io.close());

    test('the summarizer\'s thinking renders live, dimmed, before the '
        'compaction report and the continuation turn', () async {
      const window32k = Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 32768,
        maxTokens: 4096,
      );
      final env = MemoryExecutionEnv(
        cwd: '/work',
        shell: FakeShell(stdout: 'x' * 32800),
      );
      // Suppress session-start memory maintenance so the scripted turns
      // feed only the run under test (agent_cli_test pattern).
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final fake = FakeStreamFunction([
        // Three tool calls whose outputs (~8200 tokens each) push the
        // next request past the window — the over-window guard fires.
        toolTurn(const [
          ToolCall(
            id: 'c1',
            name: 'bash',
            arguments: {'command': 'cat a.log'},
          ),
          ToolCall(
            id: 'c2',
            name: 'bash',
            arguments: {'command': 'cat b.log'},
          ),
          ToolCall(
            id: 'c3',
            name: 'bash',
            arguments: {'command': 'cat c.log'},
          ),
        ]),
        // Consumed by the mid-run relief's no-op compaction attempt.
        textTurn('S'),
        // The real summarizer pass: the gh-1433 E4 contract is that its
        // THINKING renders live on the log face instead of vanishing
        // into a busy row that does not exist in a captured log.
        thinkingOnlyTurn(
          'compaction reasoning — folding three tool outputs',
          'S',
        ),
        // The continuation turn after the fold.
        textTurn('continued after compaction'),
        textTurn('spare'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: window32k,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
          compactionEngine: CompactionEngine.classic,
        ),
        io: io,
        useColor: true,
        streamFunction: fake.call,
      );
      final exit = await cli.runHeadless('go');
      final out = io.out.toString();
      expect(exit, 0, reason: out);
      expect(
        out,
        contains('\x1B[2mcompaction reasoning'),
        reason: 'the summarizer thinking must render dimmed on the log:\n'
            '$out',
      );
      // The stream line closes before the continuation lands.
      expect(
        out.indexOf('continued after compaction'),
        greaterThan(out.lastIndexOf('compaction reasoning')),
      );
    });
  });

  group('UT: AC9/E7 — background-job cards never ellipsize the log face', () {

    const psCommand =
        'ps -o pid,ppid,etime,pcpu,args -p \$(pgrep -f test.dart) '
        '2>/dev/null | cut -c1-160';
    const longLogPath = '/home/runner/work/repo/.fah/bash_jobs/'
        'sh-1234-very-long-session-identifier/job-output.log';

    TaskBlock settleCard({String command = psCommand, String? detail}) =>
        TaskBlock(
          kind: 'bash',
          id: 'sh-1234',
          state: TaskBlockState.done,
          elapsed: 2,
          label: command,
          detail:
              detail ??
              'sh-1234 · work · exit 0 · log: $longLogPath',
        );

    test('REG golden: the TUI pane keeps the width clip (ellipsis)',
        () {
      final lines = taskBlockLines(
        settleCard(command: 'echo ${'x' * 300}'),
        width: 80,
      );
      expect(lines.join('\n'), contains('…'));
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(80));
      }
    });

    test('AC9: the log face renders the FULL command soft-wrapped — no '
        'ellipsis anywhere', () {
      final lines = taskBlockLines(settleCard(), width: 80, fit: CardTextFit.wrap);
      final body = lines.join('\n');
      expect(body.contains('…'), isFalse, reason: body);
      // The command survives whole: every fragment is present and the
      // concatenation of the wrapped label rows restores it.
      final labelRows = lines
          .where((l) => l.startsWith('│ '))
          .map((l) => l.substring(2).trimRight())
          .toList();
      final joined = labelRows.join();
      expect(joined, contains('pgrep -f test.dart'));
      expect(joined, contains('cut -c1-160'));
    });

    test('AC9: the FULL log: path survives in the log face (wrapped, '
        'never clipped)', () {
      final lines = taskBlockLines(settleCard(), width: 80, fit: CardTextFit.wrap);
      final body = lines.join('\n');
      expect(body.contains('…'), isFalse, reason: body);
      // The path is soft-wrapped: the DETAIL rows concatenated restore it.
      final detailRows = lines
          .where((l) => l.startsWith('│ '))
          .map((l) => l.substring(2).trimRight())
          .join();
      expect(detailRows, contains('log: $longLogPath'));
    });

    test('AC9: a multi-line (heredoc) command renders EVERY line, not '
        'the first line + hint', () {
      const heredoc =
          "cat > /tmp/x.md << 'EOF'\nfirst body line\nsecond body line\nEOF";
      final lines = taskBlockLines(
        settleCard(command: heredoc, detail: 'sh-1234 · exit 0'),
        width: 80,
        fit: CardTextFit.wrap,
      );
      final body = lines.join('\n');
      expect(body, contains("cat > /tmp/x.md << 'EOF'"));
      expect(body, contains('first body line'));
      expect(body, contains('second body line'));
      expect(body.contains('more — bash_job output'), isFalse,
          reason: 'the full command is the point; the hint is pane economy');
    });

    test('E7: a multi-KB one-liner wraps to a bounded card with an '
        'explicit (+N more chars, see <log>) pointer — never silent', () {
      final huge = 'echo ${'y' * 5000}';
      final lines = taskBlockLines(
        settleCard(command: huge, detail: 'sh-1234 · exit 0'),
        width: 100,
        fit: CardTextFit.wrap,
      );
      final body = lines.join('\n');
      expect(body, contains('more chars, see <log>'), reason: body);
      expect(body.contains('…'), isFalse,
          reason: 'the cap is explicit, never a silent ellipsis');
      // Bounded: the 2000-char body budget / ~95-wide rows + pointer.
      final bodyRows = lines.where((l) => l.startsWith('│')).length;
      expect(bodyRows, lessThanOrEqualTo(logFaceCardMaxBodyChars ~/ 90 + 3),
          reason: body);
    });

    test('the detail builder spends the log-face budget on the log path',
        () {
      final capped = shellJobCardDetail(
        id: 'sh-1',
        logPath: '/log/${'a' * 300}.log',
        state: TaskBlockState.done,
        exitCode: 0,
      );
      expect(capped.endsWith('…'), isTrue,
          reason: 'the pane cap (issue #429) holds by default');
      final whole = shellJobCardDetail(
        id: 'sh-1',
        logPath: '/log/${'a' * 300}.log',
        state: TaskBlockState.done,
        exitCode: 0,
        maxLength: logFaceCardMaxBodyChars,
      );
      expect(whole.endsWith('…'), isFalse);
      expect(whole, contains('/log/${'a' * 300}.log'));
    });

    test('AC9: the log: pointer survives behind a pathological command '
        '(the wrap budget is per body, never shared)', () {
      // Review PRRT_kwDOTXdlLc6qt-Z0: a multi-KB command must not eat
      // the budget the `log:` pointer needs — the pointer is the thing
      // a post-hoc reader follows. The label and the detail each get
      // their own [logFaceCardMaxBodyChars] budget, so the E7 cap hits
      // the command, never the detail.
      final huge = 'echo ${'y' * 5000}';
      final lines = taskBlockLines(
        settleCard(
          command: huge,
          detail: 'sh-1234 · work · exit 0 · log: $longLogPath',
        ),
        width: 100,
        fit: CardTextFit.wrap,
      );
      final body = lines.join('\n');
      // The detail soft-wraps: concatenated body rows restore the whole
      // pointer (the AC9 assertion shape).
      final wrapped = lines
          .where((l) => l.startsWith('│ '))
          .map((l) => l.substring(2).trimRight())
          .join();
      expect(wrapped, contains('log: $longLogPath'),
          reason: 'the pointer survives whole behind the capped command:\n'
              '$body');
      expect(body, contains('more chars, see <log>'),
          reason: 'the command still caps explicitly:\n$body');
    });

    test('E7: the (+N more chars) count is exact — also when the cap '
        'lands on a physical line boundary', () {
      // Review PRRT_kwDOTXdlLc6qt-Z0 (minor): the reported remainder
      // must not drift by a newline. `emitted` never counts newlines,
      // so a flip exactly at a line boundary owns the boundary newline.
      // Mid-line flips are exact by construction (the next line's +1
      // carries the preceding newline).
      final lines = taskBlockLines(
        settleCard(
          command: '${'a' * logFaceCardMaxBodyChars}\nshort tail',
          detail: 'sh-1 · exit 0',
        ),
        width: 100,
        fit: CardTextFit.wrap,
      );
      final body = lines.join('\n');
      final pointer =
          RegExp(r'\(\+ (\d+) more chars, see <log>\)').firstMatch(body);
      expect(pointer, isNotNull, reason: body);
      expect(
        int.parse(pointer!.group(1)!),
        '\nshort tail'.length,
        reason: 'the unshown remainder is the boundary newline + the '
            'second line:\n$body',
      );
    });
  });

  group('UT: E8 — the TUI width seam tracks the live window', () {
    test('a card at 200 cols renders ~200-wide lines; the boot model '
        'never pins the seam', () {
      final controller = FaTuiController(
        callbacks: _tuiCallbacks(),
        isExited: () => false,
      );
      // The program's boot WindowSizeMsg lands before any card: the
      // controller's width seam IS the live width (not the stale 80).
      controller.model.update(WindowSizeMsg(200, 50));
      expect(controller.termWidth, 200);
      final lines = taskBlockLines(
        const TaskBlock(
          kind: 'bash',
          id: 'sh-1',
          state: TaskBlockState.done,
          label: 'echo wide',
          detail: 'sh-1 · exit 0',
        ),
        width: controller.termWidth,
      );
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(200));
      }
      expect(lines.join('\n'), contains('echo wide'));
    });

    test('resize-mid-run: a card after a window widen uses the new '
        'width — no restart needed', () {
      final controller = FaTuiController(
        callbacks: _tuiCallbacks(),
        isExited: () => false,
      );
      controller.model.update(WindowSizeMsg(120, 40));
      expect(controller.termWidth, 120);
      controller.model.update(WindowSizeMsg(200, 50));
      expect(controller.termWidth, 200, reason: 'the widen applies live');
      controller.model.update(WindowSizeMsg(90, 40));
      expect(controller.termWidth, 90, reason: 'and the shrink too');
    });

    test('E8 REG: the resize hook survives the copyWith swap — the model '
        'update() RETURNS keeps tracking resizes (the production path)',
        () {
      final controller = FaTuiController(
        callbacks: _tuiCallbacks(),
        isExited: () => false,
      );
      // Production: the program swaps to update()'s return value (the
      // busy-heartbeat alone re-copies the model on almost every
      // message) — driving controller.model directly, as the test above
      // does, always feeds the BOOT instance and discards the copies.
      // The boot instance fires the hook for the FIRST resize…
      final (swapped, _) = controller.model.update(WindowSizeMsg(120, 40));
      expect(controller.termWidth, 120);
      expect(identical(swapped, controller.model), isFalse,
          reason: 'update() returns a copy — the instance the program '
              'swaps to');
      // …but every later resize arrives on THAT copy: its WindowSizeMsg
      // must fire the hook too (copyWith carries onResized), or every
      // post-boot SIGWINCH is silently dropped and the hub cards freeze
      // at the startup width.
      final (next, _) = (swapped as FaTuiModel).update(WindowSizeMsg(200, 50));
      expect(
        controller.termWidth,
        200,
        reason: 'onResized must survive copyWith — the running copy is '
            'what production feeds',
      );
      // The chain keeps surviving copies (heartbeat churn re-copies
      // constantly mid-run).
      final (last, _) = (next as FaTuiModel).update(WindowSizeMsg(90, 40));
      expect(controller.termWidth, 90, reason: 'the shrink applies too');
      expect(last, isA<FaTuiModel>());
    });
  });

  group('REG: AC6 — structured modes stay byte-identical', () {
    late FakeCliIO io;

    setUp(() => io = FakeCliIO());
    tearDown(() => io.close());

    test('stream-json: the thinking turn projects exactly the pre-flip '
        'frame sequence — no narrative bytes leak into stdout frames',
        () async {
      final fake = FakeStreamFunction([
        narratedToolTurn(),
        textTurn('All done — found it.'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell(stdout: 'ok')),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
        ),
        // The host wiring (bin/fah_runapp.dart): structured modes wrap the
        // IO so write() deltas are dropped — stdout purity.
        io: HepEventsIO(io),
        streamFunction: fake.call,
      );
      final frames = <String>[];
      final writer = StreamJsonWriter(emit: frames.add);
      final exit = await cli.runHeadless('check', streamJson: writer);
      expect(exit, 0);
      // The captured io.out only carries the diagnostics channel —
      // the narrative write()s must be absent in structured mode.
      final types = [
        for (final line in frames)
          (jsonDecode(line) as Map<String, dynamic>)['type'] as String,
      ];
      expect(types.first, 'session');
      expect(types, contains('message_update'));
      expect(types.last, 'agent_settled');
      // The full-narrative bytes (thinking, narration) ride NO stdout
      // line: the HEP/stream-json wrapper drops write() by contract.
      expect(io.out.toString().contains('pondering'), isFalse);
      expect(io.out.toString().contains('Checking the file'), isFalse);
      // The frames themselves stay structured.
      for (final line in frames) {
        expect(() => jsonDecode(line), returnsNormally);
      }
    });

    test('HEP: the thinking turn stays pure — stdout empty, frames carry '
        'text only (thinking deltas are NOT message_delta frames)',
        () async {
      final fake = FakeStreamFunction([
        narratedToolTurn(),
        textTurn('All done — found it.'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: MemoryExecutionEnv(cwd: '/work', shell: FakeShell(stdout: 'ok')),
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
          headlessRun: true,
        ),
        // The host wiring (bin/fah.dart events mode): HepEventsIO drops
        // write() prose — the gh-1433 flip adds MORE prose writes, and
        // the decorator must drop every one of them.
        io: HepEventsIO(io),
        streamFunction: fake.call,
      );
      final frames = <String>[];
      final hep = HepWriter(emit: frames.add, fahVersion: 'test');
      final exit = await cli.runHeadless('check', hep: hep);
      expect(exit, 0);
      final out = io.out.toString();
      expect(out.contains('pondering'), isFalse, reason: out);
      expect(out.contains('Checking the file'), isFalse, reason: out);
      final parsed = [
        for (final line in frames) jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(parsed.first['type'], 'hep_header');
      expect(parsed.map((f) => f['type']), containsAllInOrder([
        'agent_start',
        'message_start',
        'turn_done',
      ]));
      final allFrames = frames.join();
      // The answer (and the pre-tool narration — both are TEXT content)
      // ride the frames; THINKING rides nothing (the HEP protocol never
      // framed thinking — byte-identical pre/post flip).
      expect(allFrames, contains('All done — found it.'));
      expect(allFrames, contains('Checking the file now.'));
      expect(allFrames, isNot(contains('pondering')));
    });
  });
}
