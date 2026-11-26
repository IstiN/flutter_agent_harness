// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// gh-241 follow-up #5d (D2/D3 — owner live test round 5): the resume walk
// is BOUNDED on every path. A zero parity budget used to become `null`,
// and `null` walked UNBOUNDED to the file head — 47–53 messages, the raw
// history earlier cuts had removed — because the walk knew classic
// compactions only, never a structured checkpoint. A zero budget now
// bounds the tail by the window minus the calibrated overhead; an
// UNMEASURED session stops at the newest durable boundary, a checkpoint
// included.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _turn = 'go onward zebra-42';

AgentCliConfig _config(Model model, MemoryExecutionEnv env, String name) =>
    AgentCliConfig(
      model: model,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: name,
      homeDir: '/home',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.structured,
      systemPrompt: tinyPrompt,
      runtimeTools: tinyTools(const ['bash']),
    );

Model _model() => Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 200000,
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

Future<MemoryExecutionEnv> _env() async {
  final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  return env;
}

Future<Session> _seed(MemoryExecutionEnv env, String name) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final seed = await repo.create(
    JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
  );
  await seed.appendSessionName(name);
  return seed;
}

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
      config: _config(_model(), probeEnv, 'probe'),
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

  /// Boots [name] over [env] and returns the resume-walk log. The CLI,
  /// its stream and its run stay with the caller.
  Future<
    ({String log, FakeStreamFunction stream, AgentCli cli, Future<void> run})
  >
  boot(MemoryExecutionEnv env, String name, {int? window}) async {
    final stream = FakeStreamFunction([textTurn('answered after resume')]);
    final cli = AgentCli(
      config: _config(
        window == null
            ? _model()
            : Model(
                id: 'test-model',
                api: 'test-api',
                provider: 'test-provider',
                baseUrl: 'https://example.test',
                contextWindow: window,
                maxTokens: 4096,
              ),
        env,
        name,
      ),
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
    return (log: log, stream: stream, cli: cli, run: run);
  }

  /// Sends the turn, exits, and returns the first request's user texts.
  Future<String> firstRequestTexts(
    FakeStreamFunction stream,
    AgentCli cli,
    Future<void> run,
  ) async {
    io.sendLine(_turn);
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'the first user turn answers',
    );
    io.sendLine('/exit');
    await run;
    return stream.contexts.first.messages
        .whereType<UserMessage>()
        .map((m) => m.content.toString())
        .join('\n');
  }

  test(
    'D2: a MEASURED zero parity budget never loads the whole branch — '
    'bounded at the newest durable boundary, else by the window minus '
    'the calibrated overhead',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final overhead = await probeHeuristicOverhead();
      final window = (overhead * 1.12).round();
      final env = await _env();
      final seed = await _seed(env, 'zero-budget-target');
      await seed.appendMessage(
        UserMessage.text('TASK build the mips interpreter'),
      );
      // The first report prices the overhead at x0.90 of the heuristic:
      // over the window minus the reserve (x0.84) — the parity budget
      // goes zero.
      await seed.appendMessage(
        _reported('the first answer', (overhead * 0.9).round() + 12),
      );
      for (var i = 0; i < 12; i++) {
        await seed.appendMessage(
          UserMessage.text('raw early $i ${'x' * 1500}'),
        );
      }
      await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      final booted = await boot(env, 'zero-budget-target', window: window);
      final log = booted.log;
      final why = '$log\n--- OUT ---\n${io.out.toString()}';
      expect(
        log,
        contains(RegExp(r'resume calibration source=first anchor=\S+ ratio=')),
        reason: why,
      );
      expect(
        log,
        contains(
          RegExp(r'budget=none \(zero: window below overhead \+ reserve — '),
        ),
        reason: why,
      );
      expect(log, isNot(contains('(unmeasured:')), reason: why);
      final tailLine = io.out
          .toString()
          .split('\n')
          .firstWhere((l) => l.contains('[resume] loaded the last'));
      final texts = await firstRequestTexts(
        booted.stream,
        booted.cli,
        booted.run,
      );
      expect(texts, isNot(contains('raw early 0')), reason: texts);
      expect(texts, contains(_turn));
      final request = booted.stream.contexts.single;
      final estimate = estimateRequestTokens(
        request.messages,
        systemPrompt: request.systemPrompt,
        tools: request.tools ?? const [],
        calibration: booted.cli.agent.state.overheadCalibration,
      );
      expect(
        estimate,
        lessThanOrEqualTo(window),
        reason: 'first request $estimate > window $window; tail: $tailLine',
      );
      expect(log, isNot(contains('over-window relief')), reason: why);
    },
  );

  test(
    'D2/D3: an UNMEASURED session stops the walk at the newest durable '
    'boundary — a checkpoint under the structured engine — never the file '
    'head',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final env = await _env();
      final seed = await _seed(env, 'unmeasured-boundary-target');
      // Raw early history NO checkpoint covers (the owner's records 4–34).
      for (var i = 0; i < 24; i++) {
        await seed.appendMessage(UserMessage.text('early raw $i ${'x' * 300}'));
      }
      final buffers = <String>[];
      for (var i = 0; i < 8; i++) {
        buffers.add(await seed.appendMessage(UserMessage.text('buffer $i')));
      }
      await seed.appendCompactCheckpoint(
        firstRecordId: buffers.first,
        lastRecordId: buffers.last,
        text: 'CHECKPOINT: the buffers are folded.',
        coversRecordIds: [buffers.last],
        flattenedRecordIds: const [],
      );
      for (var i = 0; i < 16; i++) {
        await seed.appendMessage(UserMessage.text('later raw $i'));
      }
      await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      final booted = await boot(env, 'unmeasured-boundary-target');
      final log = booted.log;
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(log, contains('budget=none (unmeasured: estimate only'));
      expect(log, isNot(contains('resume calibration source=')), reason: why);
      expect(
        out,
        contains('[resume] loaded the last'),
        reason: 'the tail line names what the boundary left out: $why',
      );
      final texts = await firstRequestTexts(
        booted.stream,
        booted.cli,
        booted.run,
      );
      expect(texts, isNot(contains('early raw 0')), reason: texts);
      expect(texts, contains('later raw 15'), reason: texts);
      expect(texts, contains(_turn));
    },
  );

  test(
    'gh-241 follow-up #5e (E1/E6 — owner live test round 6): a MEASURED '
    'resume whose budget cannot hold summary + raw tail keeps the newest '
    'checkpoint summary resident — the request opens with it, then the '
    'raw tail it does not cover — and the log names it',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final env = await _env();
      final seed = await _seed(env, 'measured-summary-first');
      // The session's first report (the D1 anchor): overhead-dominated,
      // like the owner's x0.66.
      final firstId = await seed.appendMessage(
        UserMessage.text('first question of all'),
      );
      final answerId = await seed.appendMessage(
        _reported('first answer', 2300),
      );
      // Raw early history the checkpoint covers.
      final early = <String>[];
      for (var i = 0; i < 40; i++) {
        early.add(
          await seed.appendMessage(
            UserMessage.text('early raw $i ${'x' * 300}'),
          ),
        );
      }
      final ckptId = await seed.appendCompactCheckpoint(
        firstRecordId: firstId,
        lastRecordId: early.last,
        text: 'CHECKPOINT: the early history is folded into this summary.',
        coversRecordIds: [firstId, answerId, ...early],
        flattenedRecordIds: const [],
      );
      // A raw tail bigger than the budget (the owner's big tool results).
      for (var i = 0; i < 36; i++) {
        await seed.appendMessage(UserMessage.text('later raw $i ${'y' * 900}'));
      }
      await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      final booted = await boot(env, 'measured-summary-first', window: 13000);
      final log = booted.log;
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(log, contains('resume calibration source=first'), reason: why);
      expect(log, isNot(contains('budget=none')), reason: why);
      expect(log, contains('budget='), reason: why);
      final texts = await firstRequestTexts(
        booted.stream,
        booted.cli,
        booted.run,
      );
      final lines = texts.split('\n');
      expect(
        lines.first,
        contains(':ckpt·'),
        reason: 'the summary must open the request: $texts',
      );
      expect(
        lines[1],
        contains('CHECKPOINT: the early history'),
        reason: texts,
      );
      // … then ONLY the tail the summary does not cover: after the
      // summary's own hidden index, the first conversation line is the
      // raw tail.
      final tailAt = lines.indexWhere((line) => line.contains('later raw 0'));
      expect(tailAt, greaterThan(1), reason: texts);
      final between = lines.sublist(2, tailAt);
      expect(
        between,
        // (the checkpoint text's own blank separator included)
        everyElement(
          anyOf(isEmpty, startsWith('hidden segments'), startsWith('[')),
        ),
        reason: 'nothing raw between the summary and the tail: $between',
      );
      // Covered history is not re-sent raw (the summary's hidden index
      // lists a short preview per id — by design).
      expect(texts, isNot(contains('x' * 200)), reason: texts);
      expect(texts, contains(_turn));
      expect(log, contains('resume summary sid='), reason: why);
      expect(
        log,
        contains('summary=$ckptId'),
        reason: 'the log names the summary the request opened with: $why',
      );
    },
  );

  test(
    'gh-241 follow-up #5e (E4 at boot — owner live test round 6): a '
    'MEASURED resume in the soft-window regime whose context is over the '
    'window at boot takes the LM-free boot-cap relief — reported '
    'truthfully, and the pinned summary still opens the live context',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final env = await _env();
      final seed = await _seed(env, 'measured-boot-cap-relief');
      final firstId = await seed.appendMessage(
        UserMessage.text('first question of all'),
      );
      final answerId = await seed.appendMessage(
        _reported('first answer', 2300),
      );
      final early = <String>[];
      for (var i = 0; i < 40; i++) {
        early.add(
          await seed.appendMessage(
            UserMessage.text('early raw $i ${'x' * 300}'),
          ),
        );
      }
      await seed.appendCompactCheckpoint(
        firstRecordId: firstId,
        lastRecordId: early.last,
        text: 'CHECKPOINT: the early history is folded into this summary.',
        coversRecordIds: [firstId, answerId, ...early],
        flattenedRecordIds: const [],
      );
      for (var i = 0; i < 36; i++) {
        await seed.appendMessage(UserMessage.text('later raw $i ${'y' * 900}'));
      }
      await seed.appendMessage(
        UserMessage.text('follow-up question about the registers'),
      );
      final booted = await boot(env, 'measured-boot-cap-relief', window: 900);
      await waitForIt(() => !booted.cli.isBusy, reason: 'idle after boot');
      final log = booted.log;
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(log, contains('resume calibration source=first'), reason: why);
      expect(
        log,
        contains('soft window sid='),
        reason: 'the regime must hold for the boot-cap relief: $why',
      );
      // `_bootCapMeasuredRelief` ran and `_reportBootCapRelief` said what
      // it really did — one of the two truthful forms, nothing else.
      expect(
        log,
        matches(
          RegExp(
            r'resume boot cap soft-window relief sid=\S+ tokens≈\d+ -> '
            r'≈\d+ \(estimate; (the live context was cut in memory — a '
            r'receipt is in the session|the figure moved with its basis — '
            r'nothing was cut from the live context)\)',
          ),
        ),
        reason: why,
      );
      expect(log, isNot(contains('resume boot cap skipped')), reason: why);
      // E4: the relief never costs the pinned summary its opening place.
      final live = booted.cli.agent.state.messages;
      final first = live.whereType<UserMessage>().first.content.toString();
      expect(
        first,
        matches(RegExp(r'^(m\d+ )?\[\d+(?:-\d+)?:ckpt·')),
        reason: 'the live context must open with the summary: $first',
      );
      io.sendLine('/exit');
      await booted.run;
    },
  );

  test(
    'gh-241 follow-up #5e (coverage — owner live test round 6): a MEASURED '
    'resume that is over the window at boot, where neither the soft-window '
    'relief nor the local-trim valve can cut anything, takes the boot-cap '
    'LM pass (the last resort) and reports it',
    timeout: const Timeout(Duration(minutes: 4)),
    () async {
      final env = await _env();
      final seed = await _seed(env, 'measured-boot-cap-pass');
      final question = await seed.appendMessage(
        UserMessage.text('the original question'),
      );
      final answer = await seed.appendMessage(_reported('the answer', 2300));
      await seed.appendCompactCheckpoint(
        firstRecordId: question,
        lastRecordId: answer,
        text: 'CHECKPOINT: the question is folded.',
        coversRecordIds: [question, answer],
        flattenedRecordIds: const [],
      );
      await seed.appendMessage(
        UserMessage.text('after the checkpoint ${'z' * 200}'),
      );
      // Window 100: the calibrated overhead alone (~2.2k) is over it. The
      // soft-window regime holds; the relief has nothing to hide and the
      // valve nothing droppable (the pinned summary plus one tail message
      // is the whole context) — the boot-cap LM pass is what remains.
      final stream = FakeStreamFunction([
        textTurn('summary of the boot pass'),
        textTurn('answered after resume'),
      ]);
      final cli = AgentCli(
        config: _config(
          const Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100,
            maxTokens: 4096,
          ),
          env,
          'measured-boot-cap-pass',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await waitForIt(() => !cli.isBusy, reason: 'idle after boot');
      var log = '';
      await waitForIt(() async {
        log =
            (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ??
            '';
        return log.contains('resume boot cap start');
      }, reason: 'the boot-cap line reached fa.log');
      final why = '$log\n--- OUT ---\n${io.out.toString()}';
      expect(log, contains('resume calibration source=first'), reason: why);
      expect(log, contains('resume boot cap start sid='), reason: why);
      expect(
        log,
        isNot(contains('resume boot cap local-trim sid=')),
        reason: why,
      );
      expect(log, isNot(contains('resume boot cap skipped')), reason: why);
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'gh-241 follow-up #5e (coverage): an UNANCHORED resume — no boundary, '
    'the first report beyond the calibration probe — surfaces the report '
    'through the walk and the R2 parity trim bounds the loaded context '
    'under the budget it prices',
    timeout: const Timeout(Duration(minutes: 9)),
    () async {
      final env = await _env();
      final seed = await _seed(env, 'unanchored-late-anchor');
      // The session's ONLY report sits at the file head; more records
      // than the probe reads (4096) follow it — the resident calibration
      // cannot vouch (a mid-chain tail, no boundary), so the session
      // opens unmeasured and the boundary-only walk reaches the file
      // head, surfacing the report to the late anchor (R2).
      await seed.appendMessage(UserMessage.text('the very first question'));
      await seed.appendMessage(_reported('the very first answer', 2300));
      for (var i = 0; i < 4300; i++) {
        await seed.appendMessage(UserMessage.text('filler $i ${'f' * 24}'));
      }
      final booted = await boot(env, 'unanchored-late-anchor', window: 13000);
      final log = booted.log;
      final out = io.out.toString();
      final why = '$log\n--- OUT ---\n$out';
      expect(
        log,
        contains('budget=none (unmeasured'),
        reason: 'the session opens unmeasured: $why',
      );
      expect(log, isNot(contains('resume calibration source=')), reason: why);
      expect(log, contains('resume walk sid='), reason: why);
      await waitForIt(() => !booted.cli.isBusy, reason: 'idle after boot');
      // R2: the surfaced report measures the session, and the projection
      // is trimmed to the budget it prices.
      expect(
        booted.cli.agent.state.overheadCalibration.measured,
        isTrue,
        reason: why,
      );
      expect(
        log,
        contains('older record(s) left on disk'),
        reason: 'the parity trim bounded the loaded context: $why',
      );
      io.sendLine('/exit');
      await booted.run;
    },
  );
}
