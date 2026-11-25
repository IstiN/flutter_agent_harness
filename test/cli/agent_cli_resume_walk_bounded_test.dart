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
    return stream.contexts.single.messages
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
}
