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
        : parentTurns[
            _parentCalls < parentTurns.length
                ? _parentCalls++
                : parentTurns.length - 1];
    return FakeStreamFunction([turn]).call(model, context);
  }
}

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  Future<AgentCli> bootedCli(StreamFunction stream) async {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: MemoryExecutionEnv(
          cwd: '/work',
          shell: const UnavailableShell(),
        ),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream,
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

  test('AC2a: /model-edit publishes the pin into the shared registry',
      () async {
    final cli = await bootedCli(FakeStreamFunction([textTurn('')]).call);
    io.sendLine('/model-edit contextWindow 478000');
    await waitForIt(
      () => io.out.toString().contains('478000'),
      reason: 'the pin applied',
    );
    expect(cli.contextWindowRegistry.isVerified(testModel), isTrue);
    expect(cli.contextWindowRegistry.windowFor(testModel), 478000);
  });

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
      // The pin lands first (the model instance follows /model-edit),
      // then a DETECTION the model instance never saw publishes a
      // strictly larger window — the exact fork gh-1742 exists for.
      io.sendLine('/model-edit contextWindow 4000');
      await waitForIt(
        () => io.out.toString().contains('4000'),
        reason: 'the pin applied',
      );
      cli.contextWindowRegistry.publish(
        model: testModel,
        window: 478000,
        source: ContextWindowSource.endpointReport,
      );
      expect(cli.contextWindowRegistry.windowFor(testModel), 478000);

      io.sendLine('spawn a kid');
      await waitForIt(
        () => cli.subagentManager['kid'] != null,
        reason: 'the child registers',
      );
      await waitForIt(
        () => cli.subagentManager['kid']!.windowTokens == 478000,
        reason: 'the child pressure stamp resolves the registered window',
      );
    },
  );
}
