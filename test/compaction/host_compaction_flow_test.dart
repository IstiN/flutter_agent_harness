// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2059 — the shared host compaction flow the extension SW host runs
/// (settle / relief / manual paths + the under-window re-fire ladder),
/// consumed through the same `resolveCompactionHostWiring` the CLI and the
/// app compute through.
///
/// Pins the extension host's compaction contract end-to-end on the VM:
/// - settle is gated on the shared wiring's trigger, manual /compact runs
///   unconditionally (CLI parity) and emits a before/after token notice;
/// - the relief path hands the loop's over-window guard a shrunken list or
///   null (never a still-over-window "success");
/// - the re-fire ladder gives a pass that leaves the context over-window
///   exactly ONE more run, then a VISIBLE failure notice (AC5) — the
///   incident's silent 128,040 stuck loop is unrepresentable;
/// - cancel parity (issue #1085): a cancelled compaction surfaces as
///   cancelled — never as a failed pass the funnel would re-launch;
/// - AC3 under-window invariant as a property test over generated
///   transcripts (including the newest-message-bigger-than-budget case:
///   the valve's null path surfaces as the notice, transcript intact);
/// - AC6 incident replay: 30 turns of ~60k-char tool results against a
///   128,000 window recover under-window with usage anchors cleared.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Model _model({int contextWindow = 8000}) => Model(
  id: 'm1',
  name: 'm1',
  api: 'openai-completions',
  provider: 'test',
  baseUrl: 'http://localhost:1',
  contextWindow: contextWindow,
  maxTokens: 8192,
);

/// The wiring the extension host resolves (overhead 0 — the CLI basis).
CompactionHostWiring _wiring(
  Model model, {
  CompactionSettings? settingsOverride,
  int? contextWindowCap,
}) => resolveExtensionCompactionWiring(
  mainModel: model,
  settingsOverride: settingsOverride,
  contextWindowCap: contextWindowCap,
);

/// The same resolution with the master switch off (a host that resolved
/// its compaction config off) or a fast retry ladder (test budget).
CompactionHostWiring _wiringVariant(
  Model model, {
  bool enabled = true,
  Duration baseBackoff = compactionSummarizerBaseBackoff,
}) {
  final base = _wiring(model);
  return CompactionHostWiring(
    window: base.window,
    conversationWindow: base.conversationWindow,
    settings: base.settings,
    smolModel: base.smolModel,
    enabled: enabled,
    baseBackoff: baseBackoff,
  );
}

CompactionHostWiring _offWiring(Model model) =>
    _wiringVariant(model, enabled: false);

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [TextContent(text: text), ...?calls],
      api: 'openai-completions',
      provider: 'test',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

ToolResultMessage _result(String callId, String text) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'browser_read_dom',
  content: [TextContent(text: text)],
  isError: false,
  timestamp: DateTime.utc(2026),
);

/// Scripted summarizer stream: a `<conversation>` prompt (the checkpoint
/// pass) gets a prose checkpoint answer, the judge prompt gets a small
/// JSON verdict — the same shapes the structured engine fixtures use.
StreamFunction _scriptedStream() => (model, context, {cancelToken}) {
  final last = context.messages.last;
  final promptText = switch (last) {
    UserMessage() =>
      last.content is String
          ? last.content as String
          : (last.content as List<Object>)
                .whereType<TextContent>()
                .map((b) => b.text)
                .join(),
    _ => '',
  };
  final answer = promptText.contains('<conversation>')
      ? 'checkpoint: the browsing task so far'
      : '[1, 2, 3]';
  final stream = AssistantMessageEventStream();
  final partial = _assistant(answer);
  stream
    ..push(StartEvent(partial: _assistant('')))
    ..push(TextStartEvent(contentIndex: 0, partial: _assistant('')))
    ..push(TextDeltaEvent(contentIndex: 0, delta: answer, partial: partial))
    ..push(DoneEvent(reason: StopReason.stop, message: partial));
  stream.end();
  return stream;
};

/// A summarizer stream whose calls all fail (the endpoint is down — the
/// incident's fetch death), observable via [calls].
class _FailingStream {
  _FailingStream(this.message);

  final String message;
  var calls = 0;

  StreamFunction get fn => (model, context, {cancelToken}) {
    calls++;
    final stream = AssistantMessageEventStream();
    stream.push(
      ErrorEvent(reason: StopReason.error, error: _errorAssistant(message)),
    );
    stream.end();
    return stream;
  };
}

/// A summarizer stream that cancels its token on the FIRST call and then
/// fails — the deterministic mid-run abort (issue #1085): the cancel lands
/// while the compactor run is provably still in flight.
class _CancelMidRunStream {
  _CancelMidRunStream(this.source);

  final CancelTokenSource source;

  StreamFunction get fn => (model, context, {cancelToken}) {
    source.cancel('user abort');
    final stream = AssistantMessageEventStream();
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: _errorAssistant('cancelled by user'),
      ),
    );
    stream.end();
    return stream;
  };
}

AssistantMessage _errorAssistant(String message) => AssistantMessage(
  content: const [],
  api: 'openai-completions',
  provider: 'test',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.error,
  errorMessage: message,
  timestamp: DateTime.utc(2026),
);

/// Records the flow's two notice channels (AC4/AC11: log lines answer
/// "did a pass run, what did it drop, why did it fail" on their own).
class _RecordingNotices implements HostCompactionNotices {
  final logLines = <String>[];
  final notices = <String>[];

  @override
  void log(String line) => logLines.add(line);

  @override
  void notice(String text) => notices.add(text);

  bool get anyPassLine => logLines.any((l) => l.contains('pass '));
}

/// A fat browsing-session fixture: [pairs] assistant tool-call + huge
/// `browser_read_dom`-shaped tool results (the incident's 63k-char DOM
/// dumps), plus a closing user ask.
Future<Session> _fatSession(
  JsonlSessionRepo repo, {
  int pairs = 3,
  int payloadChars = 16000,
  bool Function(int index)? skipPair,
}) async {
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
  await session.appendMessage(UserMessage.text('fill the form on this page'));
  for (var i = 0; i < pairs; i++) {
    await session.appendMessage(
      _assistant('step $i', calls: [
        ToolCall(id: 'c$i', name: 'browser_read_dom', arguments: {}),
      ]),
    );
    if (skipPair?.call(i) ?? false) continue;
    await session.appendMessage(_result('c$i', 'payload $i ${'x' * payloadChars}'));
    await session.appendMessage(_assistant('analysis $i findings'));
  }
  await session.appendMessage(UserMessage.text('submit when done'));
  return session;
}

Future<AgentState> _stateFor(
  Session session, {
  Model? model,
  String? systemPrompt,
}) async => AgentState(
  model: model ?? _model(),
  systemPrompt: systemPrompt ?? '',
  messages: [
    for (final record in await session.getEntries())
      if (record is MessageRecord) record.message,
  ],
);

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  HostCompactionFlow flowFor(
    Session session,
    AgentState state, {
    CompactionHostWiring? wiring,
    StreamFunction? stream,
    _RecordingNotices? notices,
    int maxRefires = 1,
    CompactionSettings? settingsOverride,
  }) => HostCompactionFlow(
    session: session,
    state: state,
    wiring:
        wiring ??
        _wiring(state.model, settingsOverride: settingsOverride),
    sources: AutoCompactorSources(
      // Extension wiring: smol == main (no roles chain) — the same
      // normalized shape resolveExtensionCompactionWiring produces.
      smolStream: stream ?? _scriptedStream(),
      smolModel: state.model,
      mainStream: stream ?? _scriptedStream(),
      mainModel: state.model,
    ),
    notices: notices ?? _RecordingNotices(),
    maxRefires: maxRefires,
  );

  group('settle path (gated)', () {
    test('below the trigger it is a no-op: no pass, no notice', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await flowFor(session, state, notices: notices).settle();

      expect(receipt.attempted, isFalse);
      expect(receipt.ran, isFalse);
      expect(receipt.success, isTrue);
      expect(notices.logLines, isEmpty);
      expect(notices.notices, isEmpty);
    });

    test('over the trigger it compacts and lands under the trigger', () async {
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      final wiring = _wiring(model);

      final receipt = await flowFor(
        session,
        state,
        wiring: wiring,
        notices: notices,
      ).settle();

      expect(receipt.attempted, isTrue);
      expect(receipt.ran, isTrue);
      expect(receipt.cancelled, isFalse);
      expect(
        shouldCompact(
          receipt.tokensAfter,
          wiring.conversationWindow,
          wiring.settings,
        ),
        isFalse,
        reason: 'the settle pass must land under the trigger',
      );
      expect(receipt.success, isTrue);
      // AC4/AC11: the log alone tells the pass story — at least one pass
      // line, before/after tokens, and no failure notice.
      expect(notices.logLines.where((l) => l.contains('pass ')), isNotEmpty);
      expect(notices.logLines.first, contains('start'));
      expect(notices.logLines.first, contains('tokens='));
      expect(notices.logLines.last, contains('done'));
      expect(notices.notices, isEmpty);
      // Receipt before/after are honest: the transcript really shrank.
      expect(receipt.tokensAfter, lessThan(receipt.tokensBefore));
    });

    test('disabled wiring never compacts, even over the trigger', () async {
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      const disabled = CompactionSettings(
        enabled: false,
        reserveTokens: 200,
        keepRecentTokens: 200,
      );

      final receipt = await flowFor(
        session,
        state,
        wiring: _wiring(model, settingsOverride: disabled),
        notices: notices,
      ).settle();

      expect(receipt.attempted, isFalse);
      expect(notices.logLines, isEmpty);
    });

    test('a wiring with enabled: false short-circuits every path before the '
        'trigger gate', () async {
      // The extension resolver never produces enabled: false today (the
      // resolver's `enabled` defaults on), but CompactionHostWiring is the
      // shared contract every host constructs — a host that resolves its
      // master switch off must get a not-attempted receipt on ALL paths,
      // with no logs and no notices (the flow's first gate).
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      final off = _offWiring(model);

      final flow = flowFor(session, state, wiring: off, notices: notices);

      final settleReceipt = await flow.settle();
      expect(settleReceipt.attempted, isFalse);
      final manualReceipt = await flow.manual();
      expect(manualReceipt.attempted, isFalse);
      expect(notices.logLines, isEmpty, reason: 'no start line, no pass line');
      expect(notices.notices, isEmpty);
      // The relief path is gated by the guard contract, not the switch —
      // but its inner _run still reports honestly.
      final relieved = await flow.relieveOverWindow(state.messages.toList());
      expect(relieved, isNull);
      expect(
        notices.logLines.join('\n'),
        contains('relief no-op (nothing shrank)'),
        reason: 'relief compares before/after honestly even gated off',
      );
    });
  });

  group('manual path (/compact, CLI parity)', () {
    test('runs even below the trigger and emits the before/after notice', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('small talk'));
      await session.appendMessage(_assistant('hello'));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await flowFor(session, state, notices: notices).manual();

      expect(receipt.attempted, isTrue);
      expect(receipt.cancelled, isFalse);
      // AC2: the panel notice names the before/after tokens.
      expect(notices.notices, hasLength(1));
      expect(
        notices.notices.single,
        contains('${receipt.tokensBefore}'),
      );
      expect(
        notices.notices.single,
        contains('${receipt.tokensAfter}'),
      );
    });

    test('empty transcript: the nothing-to-compact notice, no pass', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      final state = await _stateFor(session);
      final notices = _RecordingNotices();

      final receipt = await flowFor(session, state, notices: notices).manual();

      expect(receipt.attempted, isFalse);
      expect(receipt.ran, isFalse);
      expect(notices.notices.single, contains('nothing to compact'));
    });
  });

  group('re-fire ladder (AC5) + visible failure (gh-1077 AC2 shape)', () {
    test('a pass that leaves the context over-window fires exactly ONE '
        'more run, then the failure notice — transcript intact', () async {
      // Both summarizers dead AND nothing droppable (the newest message is
      // bigger than the whole keep budget — the coalesced-DOM-dump border
      // case): every run ends with the context still over the window.
      final session = await _fatSession(
        repo,
        pairs: 2,
        payloadChars: 16000,
        skipPair: (_) => true, // tool results dropped → transcript stays huge
      );
      await session.appendMessage(UserMessage.text('x' * 90000));
      final model = _model(contextWindow: 8000);
      final state = await _stateFor(session, model: model);
      final failing = _FailingStream('simulated fetch death');
      final notices = _RecordingNotices();

      final receipt = await flowFor(
        session,
        state,
        wiring: _wiring(model),
        stream: failing.fn,
        notices: notices,
        maxRefires: 1,
      ).settle();

      // Exactly two runs total: the first pass + the ONE re-fire (AC5).
      expect(receipt.runs, 2, reason: 'one pass, one re-fire, then give up');
      expect(failing.calls, greaterThanOrEqualTo(2));
      expect(receipt.success, isFalse);
      expect(receipt.cancelled, isFalse);
      // The transcript is intact — the failed ladder must not truncate it.
      expect(state.messages.length, greaterThan(0));
      // AC3's null path surfaces as the VISIBLE failure notice; the
      // incident's silent stuck state is unrepresentable.
      expect(notices.notices, hasLength(1));
      expect(notices.notices.single, contains('Context compaction failed'));
      expect(notices.notices.single, contains('simulated fetch death'));
    });
  });

  group('relief path (the loop guard contract)', () {
    test('an over-window transcript comes back shrunken, counter counts one '
        'relief', () async {
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final flow = flowFor(session, state, wiring: _wiring(model));
      final overWindow = state.messages.toList();
      expect(
        estimateRequestTokens(overWindow, systemPrompt: ''),
        greaterThanOrEqualTo(_wiring(model).window),
      );

      final relieved = await flow.relieveOverWindow(overWindow);

      expect(flow.reliefCountForTest, 1);
      expect(relieved, isNotNull);
      final wiring = _wiring(model);
      expect(
        shouldCompact(
          estimateRequestTokens(relieved!, systemPrompt: ''),
          wiring.conversationWindow,
          wiring.settings,
        ),
        isFalse,
        reason: 'the retried request must go out under-window',
      );
    });

    test('nothing shrinkable returns null — the loop refuses visibly', () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('x' * 40000));
      final model = _model(contextWindow: 8000);
      final state = await _stateFor(session, model: model);
      final failing = _FailingStream('endpoint down');
      final notices = _RecordingNotices();
      final flow = flowFor(
        session,
        state,
        wiring: _wiring(model),
        stream: failing.fn,
        notices: notices,
      );
      final before = state.messages.toList();

      final relieved = await flow.relieveOverWindow(before);

      expect(flow.reliefCountForTest, 1);
      expect(relieved, isNull);
      // Still a VISIBLE failure — never a silent state change.
      expect(notices.notices, hasLength(1));
      expect(state.messages.length, before.length);
    });

    test('a sub-window transcript is refused by the guard before any pass — '
        'the relief closure is only invoked over-window', () async {
      // The LOOP only calls the relief over-window (agent_loop guard); the
      // flow itself mirrors that precondition honestly: an under-window
      // list returns the unchanged list shrink-check outcome (no pass
      // against a healthy transcript).
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      await session.appendMessage(UserMessage.text('tiny'));
      final state = await _stateFor(session);
      final flow = flowFor(session, state);

      final relieved = await flow.relieveOverWindow(state.messages.toList());

      // Nothing shrank (nothing to compact) → null; no throw, no pass.
      expect(relieved, isNull);
      expect(flow.reliefCountForTest, 1);
    });
  });

  group('cancel parity (AC8, issue #1085)', () {
    test('a cancel before the pass short-circuits: cancelled receipt, no '
        'mutation, relief answers null', () async {
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      final source = CancelTokenSource();
      final failing = _FailingStream('must never be called');
      final flow = flowFor(
        session,
        state,
        wiring: _wiring(model),
        stream: failing.fn,
        notices: notices,
      );
      final before = state.messages.toList();

      source.cancel('user abort');

      final receipt = await flow.settle(runToken: source.token);
      expect(receipt.cancelled, isTrue);
      expect(receipt.ran, isFalse);
      expect(failing.calls, 0);
      expect(state.messages.length, before.length);
      expect(notices.notices, isEmpty, reason: 'a cancel is not a failure');

      final relieved = await flow.relieveOverWindow(
        before,
        runToken: source.token,
      );
      expect(relieved, isNull);

      final manualReceipt = await flow.manual(runToken: source.token);
      expect(manualReceipt.cancelled, isTrue);
      expect(
        notices.notices.last,
        contains('interrupted'),
        reason: 'CLI parity: a compaction-only interrupt reads as one',
      );
    });

    test('a cancel arriving mid-run never reports a failed pass', () async {
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      final source = CancelTokenSource();
      final flow = flowFor(
        session,
        state,
        wiring: _wiring(model),
        stream: _CancelMidRunStream(source).fn,
        notices: notices,
      );
      // Cancel while the run is in flight: the summarizer stream itself
      // cancels the run token on its first call — the run must surface
      // cancelled, not ok (issue #1085: never a failed-pass verdict).
      final receipt = await flow.settle(runToken: source.token);

      expect(receipt.cancelled, isTrue);
      expect(notices.notices, isEmpty);
      // Whatever passes completed before the cancel stay lossless — the
      // transcript keeps at least what it had (folds never drop records).
      expect(state.messages, isNotEmpty);
    });

    test('a cancel arriving mid-run on /compact reads as an interrupted '
        'compaction, never a failure', () async {
      // The post-run parity branch (distinct from the pre-pass gate): the
      // cancel lands DURING the pass and the path is manual — the panel
      // hears 'compaction interrupted' (CLI parity: an interrupt of a
      // compaction-only command reads as one), never the failure notice.
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      final source = CancelTokenSource();
      final flow = flowFor(
        session,
        state,
        wiring: _wiring(model),
        stream: _CancelMidRunStream(source).fn,
        notices: notices,
      );

      final receipt = await flow.manual(runToken: source.token);

      expect(receipt.cancelled, isTrue);
      expect(receipt.ran, isTrue, reason: 'the pass started before the abort');
      expect(notices.notices, hasLength(1));
      expect(notices.notices.single, contains('interrupted'));
      expect(
        notices.notices.single,
        isNot(contains('Context compaction failed')),
        reason: 'issue #1085: a cancel is never a failed pass',
      );
    });
  });

  group('retry visibility (AC4/AC11 — the transient ladder logs itself)', () {
    test('a transient first failure retries and the retry rides the log — '
        'the pass still lands under the trigger', () async {
      // The incident's fetch-death class is transient when the endpoint
      // comes back: attempt 1 dies with a connection reset (the
      // compactor's transient classifier), the retry ladder recovers on
      // attempt 2 — and the flow's log alone answers "why did it stall,
      // what recovered it" (AC11) via the onRetry hook line.
      final session = await _fatSession(repo);
      final model = _model();
      final state = await _stateFor(session, model: model);
      final notices = _RecordingNotices();
      var calls = 0;
      StreamFunction flakyThenUp() => (model, context, {cancelToken}) {
        calls++;
        final stream = AssistantMessageEventStream();
        if (calls == 1) {
          stream.push(
            ErrorEvent(
              reason: StopReason.error,
              error: _errorAssistant(
                'SocketException: Connection reset by peer (OS Error: '
                'Connection reset by peer, errno = 104)',
              ),
            ),
          );
        } else {
          final promptText = switch (context.messages.last) {
            UserMessage(:final content) =>
              content is String
                  ? content
                  : (content as List<Object>)
                        .whereType<TextContent>()
                        .map((b) => b.text)
                        .join(),
            _ => '',
          };
          final answer = promptText.contains('<conversation>')
              ? 'checkpoint: the browsing task so far'
              : '[1, 2, 3]';
          final partial = _assistant(answer);
          stream
            ..push(StartEvent(partial: _assistant('')))
            ..push(TextStartEvent(contentIndex: 0, partial: _assistant('')))
            ..push(
              TextDeltaEvent(contentIndex: 0, delta: answer, partial: partial),
            )
            ..push(DoneEvent(reason: StopReason.stop, message: partial));
        }
        stream.end();
        return stream;
      };

      final receipt = await flowFor(
        session,
        state,
        wiring: _wiringVariant(model, baseBackoff: const Duration(milliseconds: 1)),
        stream: flakyThenUp(),
        notices: notices,
      ).settle();

      expect(receipt.success, isTrue, reason: 'the retry recovered the pass');
      expect(calls, greaterThanOrEqualTo(2));
      final log = notices.logLines.join('\n');
      expect(
        log,
        contains('retrying in'),
        reason: 'AC4/AC11: the retry is visible on the host log channel',
      );
      expect(
        log,
        contains('Connection reset by peer'),
        reason: 'the log names the transient cause',
      );
    });
  });

  group('AC3 — under-window invariant, property shape', () {
    test('after any path: under the trigger, or the failure notice fired '
        '(generated transcripts, newest-bigger-than-budget included)', () async {
      final random = Random(2059);
      for (var seed = 0; seed < 12; seed++) {
        final fs = MemoryFileSystem();
        final localRepo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
        final session = await _fatSession(
          localRepo,
          pairs: 2 + random.nextInt(4),
          payloadChars: 4000 + random.nextInt(20000),
          skipPair: random.nextBool() ? (i) => i.isOdd : null,
        );
        // Sometimes coalesce one giant newest message (the DOM-dump case).
        if (random.nextBool()) {
          await session.appendMessage(
            UserMessage.text('z' * (20000 + random.nextInt(60000))),
          );
        }
        final window = 4000 + random.nextInt(5) * 1000;
        final model = _model(contextWindow: window);
        final state = await _stateFor(session, model: model);
        final notices = _RecordingNotices();
        final flow = flowFor(
          session,
          state,
          wiring: _wiring(model),
          notices: notices,
          stream: random.nextBool() ? _scriptedStream() : _FailingStream('down').fn,
        );

        final HostCompactionReceipt receipt;
        switch (random.nextInt(3)) {
          case 0:
            receipt = await flow.settle();
          case 1:
            receipt = await flow.manual();
          default:
            await flow.relieveOverWindow(state.messages.toList());
            // Relief answers null when nothing shrank (the valve's null
            // path) — the receipt + notices below still decide AC3.
            receipt = flow.lastReceiptForTest!;
        }
        final wiring = flow.wiring;
        final underTrigger = !shouldCompact(
          estimateRequestTokens(
            state.messages,
            systemPrompt: state.systemPrompt,
          ),
          wiring.conversationWindow,
          wiring.settings,
        );
        if (receipt.cancelled) continue;
        expect(
          underTrigger || notices.notices.isNotEmpty,
          isTrue,
          reason:
              'seed $seed: either the context landed under the trigger '
              '(${receipt.tokensBefore} → ${receipt.tokensAfter}) or a '
              'visible failure notice fired — never a silent still-over',
        );
        // The failure path never truncates silently.
        expect(state.messages, isNotEmpty);
      }
    });
  });

  group('AC6 — incident replay', () {
    test('30 turns of ~60k-char tool results against a 128000 window '
        'recover under-window via the settle path', () async {
      final session = await _fatSession(
        repo,
        pairs: 30,
        payloadChars: 60000,
      );
      final model = _model(contextWindow: 128000);
      final state = await _stateFor(session, model: model);
      final wiring = _wiring(model);
      final notices = _RecordingNotices();

      final beforeTokens = estimateRequestTokens(
        state.messages,
        systemPrompt: state.systemPrompt,
      );
      expect(beforeTokens, greaterThan(wiring.window));

      final receipt = await flowFor(
        session,
        state,
        wiring: wiring,
        notices: notices,
      ).settle();

      expect(receipt.success, isTrue);
      expect(
        shouldCompact(
          estimateRequestTokens(
            state.messages,
            systemPrompt: state.systemPrompt,
          ),
          wiring.conversationWindow,
          wiring.settings,
        ),
        isFalse,
        reason: 'no refusal may survive — the incident ended at window+40',
      );
      // Border case: no anchor poisoning — kept assistant generations carry
      // no stale usage anchors, so the estimate is estimate-based only.
      for (final message in state.messages.whereType<AssistantMessage>()) {
        expect(message.usage.totalTokens, 0);
      }
      // AC11: the SW log alone answers "did a pass run, what did it drop".
      final log = notices.logLines.join('\n');
      expect(log, contains('start'));
      expect(log, contains('pass '));
      expect(log, contains('done'));
    });
  });
}
