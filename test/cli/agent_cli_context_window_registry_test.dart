@TestOn('vm')
library;

/// gh-1742 invariant 2 on the CLI host: the CLI owns the shared
/// per-model context-window registry, publishes `/model-edit` pins (and
/// endpoint detections) into it, and hands it to the `task` tool — a
/// child spawned AFTER a registry entry resolves the REGISTERED window,
/// not the one its wiring model still carries (the
/// 131,072-advertised-vs-478k-served asymmetry).
///
/// - AC2a: `/model-edit contextWindow <n>` publishes a user pin.
/// - AC2b: a later registry entry (a detection the model instance
///   missed) wins for children — the executor reads the registry before
///   the carried window.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Whether the transcript carries the child's task marker anywhere in a
/// user message (the child prompt wraps the task text in framework
/// prose, so the marker is matched, not the whole text).
bool _isChildRun(Context context) {
  for (final message in context.messages) {
    if (message is! UserMessage) continue;
    final content = message.content;
    final text = content is String
        ? content
        : [
            for (final block in content as List<ContentBlock>)
              if (block is TextContent) block.text,
          ].join();
    if (text.contains('KIDMARK')) return true;
  }
  return false;
}

/// A scripted stream: a CHILD run replays a plain text turn; the parent
/// replays [parentTurns] in order.
final class _RegistryRouter {
  _RegistryRouter(this.parentTurns);

  final List<List<AssistantMessageEvent>> parentTurns;
  int _parentCalls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final turn = _isChildRun(context)
        ? textTurn('child done')
        : parentTurns[_parentCalls < parentTurns.length
              ? _parentCalls++
              : parentTurns.length - 1];
    return FakeStreamFunction([turn]).call(model, context);
  }
}

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  Future<AgentCli> bootedRichCli(Model model, [StreamFunction? stream]) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: '[REDACTED:Sensitive Value]',
        env: MemoryExecutionEnv(cwd: '/work', shell: const UnavailableShell()),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream ?? FakeStreamFunction([textTurn('')]).call,
    );
    // The REPL settles only at /exit; the test ends via tearDown.
    unawaited(cli.run());
    io.sendLine('/help');
    await waitForIt(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up',
    );
    return cli;
  }

  Future<AgentCli> bootedCli(StreamFunction stream) =>
      bootedRichCli(testModel, stream);

  test(
    'AC2a: /model-edit publishes the pin into the shared registry',
    () async {
      final cli = await bootedCli(FakeStreamFunction([textTurn('')]).call);
      io.sendLine('/model-edit contextWindow 478000');
      await waitForIt(
        () => io.out.toString().contains('478000'),
        reason: 'the pin applied',
      );
      expect(cli.contextWindowRegistry.isVerified(testModel), isTrue);
      expect(cli.contextWindowRegistry.windowFor(testModel), 478000);
    },
  );

  test(
    'gh-1742 review round 1, comment 5: the limits swap preserves every '
    'Model field (one shared copyWith, no second hand-rolled field list)',
    () async {
      // A model carrying the fields a hand-rolled 18-field copy tends to
      // forget (thinkingLevel, capabilityNotes, the scoped watchdogs +
      // their label — all recent additions): the /model-edit swap must
      // keep them. _replaceModelLimits drops exactly these today.
      const richModel = Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        reasoning: true,
        input: ['text', 'image'],
        thinkingLevel: 'medium',
        cost: ModelCost(input: 1, output: 2),
        contextWindow: 100000,
        maxTokens: 4096,
        headers: {'x-a': 'b'},
        authHeader: 'x-key',
        capabilityNotes: ['gate drop note'],
        connectTimeout: Duration(seconds: 7),
        streamIdleTimeout: Duration(seconds: 90),
        timeoutScopeLabel: 'role smol override',
      );
      final cli = await bootedRichCli(richModel);
      io.sendLine('/model-edit contextWindow 478000');
      await waitForIt(
        () => io.out.toString().contains('478000'),
        reason: 'the pin applied',
      );
      final model = cli.agent.state.model;
      // The swap itself…
      expect(model.contextWindow, 478000);
      // …and everything the hand-rolled copy used to drop:
      expect(model.thinkingLevel, 'medium');
      expect(model.reasoning, isTrue);
      expect(model.input, ['text', 'image']);
      expect(model.cost.input, 1);
      expect(model.headers, {'x-a': 'b'});
      expect(model.authHeader, 'x-key');
      expect(model.capabilityNotes, ['gate drop note']);
      expect(model.connectTimeout, const Duration(seconds: 7));
      expect(model.streamIdleTimeout, const Duration(seconds: 90));
      expect(model.timeoutScopeLabel, 'role smol override');
    },
  );

  test(
    'AC2b: a child spawned after the registry entry resolves the '
    'registered window, not the carried one',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final router = _RegistryRouter([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'task',
            arguments: {
              'context': 'ctx',
              'background': false,
              'tasks': [
                {'name': 'kid', 'agent': 'task', 'task': 'KIDMARK do work'},
              ],
            },
          ),
        ]),
        textTurn('child settled, done'),
      ]);
      final cli = await bootedCli(router.call);
      // A DETECTION the model instance never saw publishes a strictly
      // larger window than the carried one — the exact fork gh-1742
      // exists for. (The `/model-edit` publish provenance is covered by
      // AC2a; driving it here wedges the next REPL line behind the
      // model re-init, so the consume half is proven with a direct
      // publish.)
      cli.contextWindowRegistry.publish(
        model: testModel,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      expect(cli.contextWindowRegistry.windowFor(testModel), 478000);

      io.sendLine('spawn a kid');
      await waitForIt(
        () => cli.subagentManager['kid'] != null,
        reason:
            'the child registers (out tail: ${io.out.toString().substring((io.out.toString().length - 700).clamp(0, io.out.toString().length))})',
      );
      await waitForIt(
        () => cli.subagentManager['kid']!.windowTokens == 478000,
        reason: 'the child pressure stamp resolves the registered window',
      );
    },
  );
}
