// gh-2237 — CLI-level integration tests for the compaction receipt
// contract:
//
// IT-2/E4: a receipt-free funnel attempt is impossible — a
//   message-cap-armed post-run attempt on a transcript under the token
//   trigger closes with done receipts (the cap force + gh-1742 classic
//   fall-through), never leaves a start as the last receipt (REG-1),
//   and never reaches the structured judge/checkpoint ladder.
// IT-5/IT-1: an anchored over-trigger transcript still folds ≥1 pass —
//   the lab cascade shape. The pre-fix engine collapsed the anchored
//   basis to chars/4, exited under-trigger with zero passes, and
//   re-fired the gate every turn (the field S1 loop).
// REG-2/IT-3: forced `/compact` on an under-trigger transcript still
//   prints a visible fold (classic fall-through intact — the probe
//   parity the lab proved is by code, not transcript shape).

library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/receipt_scan.dart';
import 'package:test/test.dart';

import '../support/scripted_stream_harness.dart' as harness;

import 'agent_cli_test_support.dart';

const _provider = 'test-provider';

/// The compaction-lane fake: judge calls (the context-hygiene judge
/// prompt) answer `[]` (hide nothing), checkpoint calls (the "Write a
/// checkpoint" payload) answer a canned summary, real turns answer from
/// [turnAnswers] — optionally carrying a scripted usage anchor.
final class _RecordingCompactionStream {
  final turnAnswers = <String>[];
  final contexts = <Context>[];
  int judgeCalls = 0;
  int checkpointCalls = 0;
  Usage? nextTurnUsage;
  var _answered = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final system = context.systemPrompt ?? '';
    final prompt = [
      for (final m in context.messages)
        switch (m) {
          UserMessage() => messageText(m),
          AssistantMessage() =>
            m.content.whereType<TextContent>().map((b) => b.text).join(),
          _ => '',
        },
    ].join('\n');
    final String reply;
    if (system.contains('context-hygiene judge')) {
      judgeCalls++;
      reply = '[]';
    } else if (prompt.contains('Write a checkpoint')) {
      checkpointCalls++;
      reply = 'CHECKPOINT: the probe task summary.';
    } else {
      reply = turnAnswers[_answered++ % turnAnswers.length];
    }
    final full = harness.testAssistant(
      content: [TextContent(text: reply)],
      usage: nextTurnUsage,
    );
    final stream = AssistantMessageEventStream();
    stream
      ..push(StartEvent(partial: harness.testAssistant()))
      ..push(DoneEvent(reason: StopReason.stop, message: full))
      ..end();
    return stream;
  }
}

AgentCli _cli(
  MemoryExecutionEnv env,
  FakeCliIO io,
  _RecordingCompactionStream stream, {
  int contextWindow = 100000,
  CompactionSettings? compactionSettings,
  Map<String, String> environment = const {},
  String homeDir = '/home',
}) => AgentCli(
  config: AgentCliConfig(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: _provider,
      baseUrl: 'https://example.test',
      contextWindow: contextWindow,
      maxTokens: 4096,
    ),
    apiKey: '[REDACTED:Sensitive-Value]',
    env: env,
    sessionRoot: '/sessions',
    sessionName: 'zero-pass-receipt-target',
    homeDir: homeDir,
    providerKind: 'openai-completions',
    skillsAccess: SkillsAccess.granted,
    compactionSettings: compactionSettings,
  ),
  io: io,
  environment: environment,
  streamFunction: stream.call,
);

Future<(MemoryExecutionEnv, Session)> _seed() async {
  final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
  // Suppress session-start memory maintenance (suite pattern).
  await env.writeFile('/work/.fah/memory/.last_maintenance', '');
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final seed = await repo.create(
    JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
  );
  await seed.appendSessionName('zero-pass-receipt-target');
  await seed.appendMessage(UserMessage.text('TASK probe ${'t ' * 100}'));
  for (var i = 0; i < 40; i++) {
    await seed.appendMessage(UserMessage.text('filler$i ${'x' * 100}'));
  }
  return (env, seed);
}

/// [waitUntil] with a LAZY description: names the state actually reached.
Future<void> waitUntil(
  bool Function() condition,
  String Function() describe,
) async {
  for (var i = 0; i < 5000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${describe()}');
}

Future<String> _readLog(MemoryExecutionEnv env, String homeDir) async {
  final log = (await env.readTextFile('$homeDir/.fah/logs/fa.log')).valueOrNull;
  expect(log, isNotNull, reason: 'the diagnostic log must exist');
  return log!;
}

void main() {
  test(
    'IT-2/E4: cap-armed funnel attempt is receipt-covered — REG-1 clean, '
    'structured ladder untouched',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final io = FakeCliIO();
      final (env, _) = await _seed();
      // A learned numeric cap below the live message count: the gh-1680
      // cap gate arms the funnel while the token basis (~2.5k chars/4
      // tokens) sits far under the token trigger — the E4 shape, and
      // post-AC1 the ONLY reachable zero-pass arming. The caps sidecar
      // is read with dart:io (outside the ExecutionEnv abstraction), so
      // it lives in a real temp home directory.
      final home = await Directory.systemTemp.createTemp('fah-gh2237-caps');
      addTearDown(() => home.deleteSync(recursive: true));
      final capsDir = Directory('${home.path}/.fah')
        ..createSync(recursive: true);
      File('${capsDir.path}/model_caps.json').writeAsStringSync(
        jsonEncode({
          ModelCapsStore.keyOf(_provider, 'test-model'): {'maxMessages': 20},
        }),
      );
      final stream = _RecordingCompactionStream()..turnAnswers.add('ok');
      final agent = _cli(
        env,
        io,
        stream,
        contextWindow: 100000,
        // Trigger 99900 — far above the basis: the token gate never fires.
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 50,
        ),
        homeDir: home.path,
      );
      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () =>
            stream.contexts.isNotEmpty &&
            stream.contexts.any(
              (c) => (c.systemPrompt ?? '').startsWith('You are Fa'),
            ) &&
            !agent.isBusy,
        () => 'turn: calls=${stream.contexts.length} busy=${agent.isBusy}',
      );
      io.sendLine('/exit');
      await run;

      final log = await _readLog(env, home.path);
      final compactLines = log
          .split('\n')
          .where((line) => line.contains('auto-compact'))
          .toList();
      expect(
        compactLines.where((line) => line.contains('auto-compact start')),
        isNotEmpty,
        reason: 'the fixture must arm the funnel (cap gate)',
      );
      // AC2/E4: every armed funnel attempt is receipt-covered — done
      // receipts exist and REG-1's start-without-terminal-receipt
      // signature is absent from the whole log. (The cap channel FORCES
      // the structured engine — gh-1680 AC4 — and a forced zero-pass
      // falls through to the classic engine — gh-1742 — whose pass and
      // done receipts close the run; post-AC1 the unforced passes=0
      // no-op is unreachable from the CLI because gate and engine
      // measure the same basis, which is the defect this card fixes.)
      expect(
        compactLines.where((line) => line.contains('auto-compact done')),
        isNotEmpty,
        reason: 'every started compaction closes with a done receipt',
      );
      expect(
        compactionStartWithoutTerminalReceipt(log.split('\n')),
        isFalse,
        reason: 'REG-1: no start may be the last receipt',
      );
      // PF5-adjacent, observable: the structured judge/checkpoint ladder
      // never ran on this arming (the cap force + classic fall-through
      // kept gh-1680/gh-1742 semantics).
      expect(stream.judgeCalls, 0);
      expect(stream.checkpointCalls, 0);
    },
  );

  test(
    'IT-5: anchored over-trigger transcript folds ≥1 pass (no collapse)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final io = FakeCliIO();
      final (env, _) = await _seed();
      // The lab shape: the LIVE turn reports a scripted 55k-token usage
      // anchor. The anchor rides state.messages (the gate's basis) AND
      // the fresh turn's session record (the projection's basis) —
      // 55k over the 45k trigger on both sides, while the chars/4
      // projection (~2.5k) sits far under it: the exact divergence that
      // used to zero-pass the engine. (A seeded anchor would not do:
      // the CLI deliberately re-anchors loaded records at chars/4 on
      // resume — a separate fix — so the gate must see a THIS-process
      // anchor.)
      final stream = _RecordingCompactionStream()
        ..turnAnswers.add('ok')
        ..nextTurnUsage = const Usage(
          input: 50000,
          output: 5000,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 55000,
          cost: UsageCost(),
        );
      final agent = _cli(
        env,
        io,
        stream,
        contextWindow: 60000,
        // Trigger 60000 - 15000 = 45000; the anchored basis (55k) fires.
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 15000,
          keepRecentTokens: 750,
        ),
      );
      final run = agent.run();
      io.sendLine('go');
      await waitUntil(
        () =>
            stream.contexts.any(
              (c) => (c.systemPrompt ?? '').startsWith('You are Fa'),
            ) &&
            !agent.isBusy,
        () => 'turn: calls=${stream.contexts.length} busy=${agent.isBusy}',
      );
      io.sendLine('/exit');
      await run;

      final log = await _readLog(env, '/home');
      final compactLines = log
          .split('\n')
          .where((line) => line.contains('auto-compact'))
          .toList();
      expect(
        compactLines.where((line) => line.contains('auto-compact start')),
        isNotEmpty,
      );
      expect(
        compactLines.where((line) => line.contains('auto-compact pass')),
        isNotEmpty,
        reason:
            'AC6/IT-5: the anchored over-trigger basis must reach the '
            'pass ladder — the collapsed zero-pass exit is the defect',
      );
      expect(
        compactLines.where(
          (line) =>
              line.contains('auto-compact done') && !line.contains('passes=0'),
        ),
        isNotEmpty,
        reason: 'the fold run closes with a receipted done',
      );
      expect(stream.checkpointCalls, greaterThanOrEqualTo(1));
      expect(
        compactionStartWithoutTerminalReceipt(log.split('\n')),
        isFalse,
        reason: 'REG-1: every start must be closed by a terminal receipt',
      );
    },
  );

  test(
    'REG-2/IT-3: /compact on an under-trigger transcript still folds a '
    'visible pass',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final io = FakeCliIO();
      final (env, _) = await _seed();
      final stream = _RecordingCompactionStream()
        ..turnAnswers.addAll(['ok', 'folded summary of the probe task']);
      final agent = _cli(
        env,
        io,
        stream,
        contextWindow: 100000,
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 100,
          keepRecentTokens: 50,
        ),
      );
      final run = agent.run();
      io.sendLine('/compact');
      await waitUntil(
        () => !agent.isBusy && stream.turnAnswers.isNotEmpty,
        () => 'compact: calls=${stream.contexts.length}',
      );
      io.sendLine('/exit');
      await run;

      final log = await _readLog(env, '/home');
      final compactLines = log
          .split('\n')
          .where((line) => line.contains('auto-compact'))
          .toList();
      expect(
        compactLines.where((line) => line.contains('auto-compact pass')),
        isNotEmpty,
        reason: 'AC5: the manual forced fold is visible on the log',
      );
      // The user-facing report block rendered (the probe parity).
      expect(io.out.toString(), contains('compacted'));
    },
  );
}
