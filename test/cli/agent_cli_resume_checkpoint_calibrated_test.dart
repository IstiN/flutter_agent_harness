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
      final window = (heuristicOverhead * 1.12).round();
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
      final messages = stream.contexts.single.messages;
      expect(
        messages.whereType<UserMessage>().map((m) => m.content).last,
        _turn,
      );
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
    expect(
      request.messages.whereType<UserMessage>().map((m) => m.content).last,
      _turn,
    );
    final first = estimateRequestTokens(
      request.messages,
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
