// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// gh-241 follow-up #5c (C1 — owner live test round 4): a resume right
// after a durable checkpoint is MEASURED. The overhead calibration is a
// property of the system prompt + the tool schemas, not of the folded
// history, so the provider report that priced an EARLIER request still
// vouches for it. Before: the checkpoint was the last record, the
// resident tail measured nothing → `budget=none (unmeasured: estimate
// only)` → the soft-window regime → warnings + an in-memory trim, with
// the heuristic at ≈35,910 against a provider truth of 15,310.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _turn = 'go onward zebra-42';

/// The fixture config (tinyPrompt + tinyTools) over [model], booting the
/// session named [name] under [sessionRoot].
AgentCliConfig _config(
  Model model,
  MemoryExecutionEnv env,
  String name,
  String sessionRoot, {
  String homeDir = '/home',
}) => AgentCliConfig(
  model: model,
  apiKey: '[REDACTED:Sensitive-Value]',
  env: env,
  sessionRoot: sessionRoot,
  sessionName: name,
  homeDir: homeDir,
  providerKind: 'openai-completions',
  skillsAccess: SkillsAccess.granted,
  compactionEngine: CompactionEngine.structured,
  systemPrompt: tinyPrompt,
  runtimeTools: tinyTools(const ['bash']),
);

Model _model(int contextWindow) => Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: contextWindow,
  maxTokens: 4096,
);

AssistantMessage _reported(String text, int promptTokens) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage(
    input: promptTokens,
    output: 100,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: promptTokens + 100,
    cost: const UsageCost(),
  ),
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  /// The heuristic overhead of this fixture in THIS environment (the
  /// composed prompt carries dynamic sections): probed from a real first
  /// request, never guessed. Closes [io] and leaves a fresh one behind.
  Future<int> probeHeuristicOverhead() async {
    final probeEnv = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await probeEnv.writeFile('/work/.fah/memory/.last_maintenance', '');
    final probeStream = FakeStreamFunction([textTurn('probe answer')]);
    final probe = AgentCli(
      config: _config(_model(200000), probeEnv, 'probe', '/probe-sessions'),
      io: io,
      streamFunction: probeStream.call,
    );
    final probeRun = probe.run();
    await waitForIt(() => probe.agent.state.tools.isNotEmpty);
    io.sendLine('probe ping');
    await waitForIt(
      () => probeStream.contexts.isNotEmpty && !probe.isBusy,
      reason: 'the probe request went out',
    );
    io.sendLine('/exit');
    await probeRun;
    io.close();
    io = FakeCliIO();
    final probeContext = probeStream.contexts.first;
    return estimateRequestOverheadTokens(
      probeContext.systemPrompt,
      probeContext.tools ?? const [],
    );
  }

  test(
    'resume right after a compact_checkpoint: budget=<n> calibrated '
    '(reported), no soft window, no warning, no in-memory trim, the first '
    'request carries the turn verbatim',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final heuristicOverhead = await probeHeuristicOverhead();
      // #2416 merge: the slim manifest shrank the seam the 1.12×
      // multiplier was sized against — at the merged ~2.7k seam the old
      // window left the metered resume estimate ABOVE the post-run
      // hand-over line (W − reserve − runway), so the settle funnel fired
      // a second model call on a degenerate checkpoint-only tail (the
      // pass failed, the turn was retried, contexts.single threw).
      // window = overhead + 680 keeps the same owner shape on the merged
      // seam: the raw-heuristic regime precondition holds (0.75W < H),
      // the calibrated x0.7 estimate sits UNDER the trigger (regime off,
      // no warning), and UNDER the post-run hand-over line (one request,
      // no relief, no trim).
      final window = heuristicOverhead + 680;
      final reserve = window ~/ 4;
      // The window puts the session in the SOFT-WINDOW regime on the raw
      // heuristic and takes it out once calibrated at x0.7 — the owner's
      // shape (window 25k: ≈23.8k estimated overhead vs ≈14.4k real).
      expect(
        window - reserve,
        lessThan(heuristicOverhead),
        reason: 'uncalibrated: the soft-window regime',
      );
      expect(
        window - reserve,
        greaterThan((heuristicOverhead * 0.75).round()),
        reason: 'calibrated x0.7: under the window, budget > 0',
      );

      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final seed = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await seed.appendSessionName('checkpoint-calibrated-target');
      final first = await seed.appendMessage(
        UserMessage.text('TASK build the mips interpreter'),
      );
      // The provider priced that request at ≈x0.7 of the heuristic.
      final promptTokens = (heuristicOverhead * 0.7).round() + 12;
      await seed.appendMessage(
        AssistantMessage(
          content: const [TextContent(text: 'the first answer')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage(
            input: promptTokens,
            output: 100,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: promptTokens + 100,
            cost: const UsageCost(),
          ),
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      final last = await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      // The durable checkpoint is the LAST record of the file.
      await seed.appendCompactCheckpoint(
        firstRecordId: first,
        lastRecordId: last,
        text:
            'CHECKPOINT: the mips interpreter task stays open; the '
            'registers are next.',
        coversRecordIds: [first, last],
        flattenedRecordIds: const [],
      );

      final stream = FakeStreamFunction([textTurn('answered after resume')]);
      final cli = AgentCli(
        config: _config(
          _model(window),
          env,
          'checkpoint-calibrated-target',
          '/sessions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy, reason: 'idle after boot');
      expect(stream.calls, 0, reason: 'no model call at boot');

      // The diagnostic log is an async chain: wait for the flush.
      var log = '';
      await waitForIt(() async {
        log =
            (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ??
            '';
        return log.contains('resume walk');
      }, reason: 'the resume-walk line reached fa.log');
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(
        log,
        contains(
          RegExp(
            r'resume walk sid=\S+ budget=\d+ calibrated x[0-9.]+ \(reported\)',
          ),
        ),
        reason: why,
      );
      expect(log, isNot(contains('unmeasured: estimate only')), reason: why);
      expect(log, isNot(contains('soft window sid=')), reason: why);
      expect(log, isNot(contains('over-window relief')), reason: why);

      io.sendLine(_turn);
      await waitForIt(
        () => stream.calls >= 1 && !cli.isBusy,
        reason: 'the first user turn answers',
      );
      io.sendLine('/exit');
      await run;

      final after = io.out.toString();
      expect(
        after,
        isNot(contains('below the fixed request overhead')),
        reason: after,
      );
      expect(after, isNot(contains('older message(s) were dropped')));
      // The turn's request is the FIRST context. Under the merged
      // machinery (gh-2423 post-hide notice + the slim manifest's smaller
      // overhead) a post-run fold may add a summarizer context after it,
      // so `.single` no longer holds — same seam as the sibling
      // resume_boot_cap locator fix.
      final messages = stream.contexts.first.messages;
      // gh-2423 C3: the near-limit notice (the calibrated estimate sits in
      // the band of this small fixture window) rides the first request as
      // the LAST message — the queued-notice delivery contract. The turn
      // itself is still the last REAL user message.
      expect(
        messages
            .whereType<UserMessage>()
            .map((m) => m.content)
            .where((c) => !isContextNoticeText(userMessageText(c)))
            .last,
        _turn,
      );
    },
  );
  test(
    'D1: the overhead ratio comes from the session\'s FIRST report, never '
    'from a tail-heavy post-boundary reply — budget > 0, no soft window, '
    'no relief',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final heuristicOverhead = await probeHeuristicOverhead();
      final window = (heuristicOverhead * 1.12).round();
      final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
      await env.writeFile('/work/.fah/memory/.last_maintenance', '');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final seed = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      await seed.appendSessionName('first-anchor-target');
      // The session's FIRST request is overhead-dominated: the provider
      // priced it at x0.66 of the heuristic (the owner's x0.66).
      final first = await seed.appendMessage(
        UserMessage.text('TASK build the mips interpreter'),
      );
      final firstPrompt = (heuristicOverhead * 0.66).round() + 12;
      final firstAnchor = await seed.appendMessage(
        _reported('the first answer', firstPrompt),
      );
      // Early raw history NO checkpoint covers (the owner's records
      // 4–34): a bounded resume must not bring it back (D3/D7).
      for (var i = 0; i < 6; i++) {
        await seed.appendMessage(
          UserMessage.text('early raw $i ${'x' * 1200}'),
        );
      }
      final fillers = <String>[];
      for (var i = 0; i < 6; i++) {
        fillers.add(
          await seed.appendMessage(UserMessage.text('filler$i ${'f' * 1500}')),
        );
      }
      await seed.appendCompactCheckpoint(
        firstRecordId: first,
        lastRecordId: fillers.last,
        text: 'CHECKPOINT: the mips interpreter task stays open.',
        coversRecordIds: [first, ...fillers],
        flattenedRecordIds: const [],
      );
      // A TAIL-HEAVY reply after the boundary, priced at x0.9: anchoring
      // on it reads the overhead ≈25 % too high and switches the
      // soft-window regime on (window − reserve = x0.84 of the heuristic).
      const checkpointText =
          'CHECKPOINT: the mips interpreter task stays '
          'open.';
      const postTurn = 'post-boundary turn about the registers';
      final tailEst =
          estimateTokens(UserMessage.text(checkpointText)) +
          estimateTokens(UserMessage.text(postTurn));
      await seed.appendMessage(UserMessage.text(postTurn));
      await seed.appendMessage(
        _reported(
          'the post-boundary answer',
          ((heuristicOverhead + tailEst) * 0.9).round(),
        ),
      );
      await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      final stream = FakeStreamFunction([textTurn('answered after resume')]);
      // gh-241 follow-up #5e (E2): the pre-flight pass's failed judge
      // calls used to eat the ONLY scripted answer, so the MAIN request
      // itself errored (`turn end … stop=error`) behind a vacuous
      // assertion. The main request (a multi-message context; the
      // pass's prompts are single-message ones) now gets its answer
      // just in time — the judge flow above it is unchanged.
      AssistantMessageEventStream routed(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        if (context.messages.length > 1) {
          stream.turns.insert(0, textTurn('answered after resume'));
        }
        return stream.call(model, context, cancelToken: cancelToken);
      }

      final cli = AgentCli(
        config: _config(
          _model(window),
          env,
          'first-anchor-target',
          '/sessions',
        ),
        io: io,
        streamFunction: routed,
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy, reason: 'idle after boot');
      expect(stream.calls, 0, reason: 'no model call at boot');
      var log = '';
      await waitForIt(() async {
        log =
            (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ??
            '';
        return log.contains('resume walk');
      }, reason: 'the resume-walk line reached fa.log');
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(
        log,
        contains(
          'resume calibration source=first anchor=$firstAnchor ratio=x0.66',
        ),
        reason: why,
      );
      expect(
        log,
        contains(
          RegExp(
            r'resume walk sid=\S+ budget=\d+ calibrated x0\.66 \(reported\)',
          ),
        ),
        reason: why,
      );
      expect(log, isNot(contains('soft window sid=')), reason: why);
      expect(log, isNot(contains('over-window relief')), reason: why);
      io.sendLine(_turn);
      await waitForIt(
        () => stream.calls >= 1 && !cli.isBusy,
        reason: 'the first user turn answers',
      );
      io.sendLine('/exit');
      await run;
      final after = io.out.toString();
      expect(
        after,
        isNot(contains('below the fixed request overhead')),
        reason: after,
      );
      expect(after, isNot(contains('older message(s) were dropped')));
      // gh-241 follow-up #5e (E1): the boundary-resident context is no
      // longer budget-trimmed, so a first turn over the trigger runs its
      // pre-flight pass first — the MAIN request is the multi-message one.
      final main = stream.contexts.firstWhere(
        // (the pass's summarizer prompts are single-message contexts)
        (c) => c.messages.length > 1,
      );
      expect(
        main.messages.whereType<UserMessage>().map((m) => m.content.toString()),
        contains(anyOf(equals(_turn), endsWith(_turn))),
      );
      // gh-241 follow-up #5e (E1): the boundary-resident window is not
      // budget-trimmed, so the resume itself cuts nothing — no tail
      // line — and the main request OPENS with the checkpoint summary.
      // The first turn's pre-flight pass (summarizer down in this
      // fixture) trims in memory with the summary pinned: the OLDEST raw
      // history is gone from the request, the summary stays.
      final texts = main.messages
          .whereType<UserMessage>()
          .map((m) => m.content.toString())
          .join('\n');
      expect(texts, isNot(contains('early raw 0')), reason: texts);
      expect(
        main.messages.whereType<UserMessage>().first.content.toString(),
        matches(RegExp(r'^(m\d+ )?\[\d+(?:-\d+)?:ckpt·')),
        reason: 'the summary opens the request: $texts',
      );
      // gh-241 follow-up #5e (E1, orchestrator decision 02:56): HEAD's
      // budget walk runs FIRST (its route is byte-for-byte HEAD's
      // whenever it reaches a boundary — the resume boot-cap pins
      // AC3/AC5); here it stopped in the raw tail and E1 paged back to
      // the boundary. The walk's report still names the records beyond
      // the boundary, so the tail line MAY print — at most once, and
      // only as the truthful boundary-bounded note carrying the summary,
      // never with parity-cut wording.
      final tailLines = io.out
          .toString()
          .split('\n')
          .where((line) => line.contains('[resume] loaded the last'))
          .toList();
      expect(tailLines, hasLength(lessThanOrEqualTo(1)), reason: why);
      for (final line in tailLines) {
        expect(line, contains('(summary='), reason: line);
        expect(line, isNot(contains('parity')), reason: line);
        expect(line, isNot(contains('cut')), reason: line);
      }
      // … and (orchestrator decision, round 7): an over-trigger first
      // request takes the EXISTING first-turn pre-flight compaction path
      // — honestly: no `turn end stop=error` precedes what follows.
      final logAfter =
          (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';
      final firstTurn = logAfter.substring(
        logAfter.indexOf('resume walk sid=') > 0
            ? logAfter.indexOf('resume walk sid=')
            : 0,
      );
      expect(
        firstTurn,
        matches(RegExp(r'(auto-compact|compaction|over-window relief)')),
        reason: 'the first turn runs the pre-flight path: $firstTurn',
      );
      expect(
        logAfter,
        isNot(matches(RegExp(r'turn end sid=\S+ stop=error'))),
        reason: logAfter,
      );
      expect(logAfter, contains('run end sid='), reason: logAfter);
    },
  );
  test('C4: the tail line prints overhead + the estimated tail — the number '
      'the first request is metered at', () async {
    final heuristicOverhead = await probeHeuristicOverhead();
    // Window: the parity budget lands at ≈5.5k, so a 40-filler tail is
    // trimmed to a few records (K < N → the tail line) and the first
    // request sits clearly UNDER the compaction trigger (no pre-flight
    // pass: the request IS the loaded tail + the prompt).
    final window = ((5500 + heuristicOverhead * 0.7) / 0.75).round();

    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('tail-figure-target');
    await seed.appendMessage(
      UserMessage.text('TASK build the mips interpreter'),
    );
    final promptTokens = (heuristicOverhead * 0.7).round() + 12;
    await seed.appendMessage(
      AssistantMessage(
        content: const [TextContent(text: 'the first answer')],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage(
          input: promptTokens,
          output: 100,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: promptTokens + 100,
          cost: const UsageCost(),
        ),
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await seed.appendMessage(UserMessage.text('filler$i ${'f' * 4000}'));
    }

    final stream = FakeStreamFunction([textTurn('answered after resume')]);
    final cli = AgentCli(
      config: _config(_model(window), env, 'tail-figure-target', '/sessions'),
      io: io,
      streamFunction: stream.call,
    );
    final run = cli.run();
    await waitForIt(() => !cli.isBusy, reason: 'idle after boot');
    expect(stream.calls, 0, reason: 'no model call at boot');

    var log = '';
    await waitForIt(() async {
      log =
          (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';
      return log.contains('resume walk');
    }, reason: 'the resume-walk line reached fa.log');
    expect(
      log,
      contains(RegExp(r'budget=\d+ calibrated x[0-9.]+ \(reported\)')),
      reason: log,
    );
    final tailLine = io.out
        .toString()
        .split('\n')
        .firstWhere((l) => l.contains('[resume] loaded the last'));
    final shown = int.parse(
      RegExp(r'≈(\d+) tokens').firstMatch(tailLine)!.group(1)!,
    );

    io.sendLine(_turn);
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'the first user turn answers',
    );
    io.sendLine('/exit');
    await run;

    final request = stream.contexts.single;
    // gh-2423 C3: the near-limit notice rides this request last (the
    // queued-notice delivery contract; the calibrated estimate sits in
    // this small fixture window's band). It is harness chrome, not
    // metered session content — exclude it from the turn-verbatim and
    // tail-figure arithmetic.
    final metered = request.messages
        .where(
          (m) =>
              !(m is UserMessage &&
                  isContextNoticeText(userMessageText(m.content))),
        )
        .toList();
    expect(metered.whereType<UserMessage>().map((m) => m.content).last, _turn);
    final first = estimateRequestTokens(
      metered,
      systemPrompt: request.systemPrompt,
      tools: request.tools ?? const [],
      calibration: cli.agent.state.overheadCalibration,
    );
    final prompt = estimateTokens(UserMessage.text(_turn));
    expect(
      shown + prompt,
      closeTo(first, 4),
      reason:
          'tail line: $tailLine\nfirst request: $first tokens '
          '(prompt $prompt)',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
