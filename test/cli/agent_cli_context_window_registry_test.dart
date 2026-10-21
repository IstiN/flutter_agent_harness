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

/// The last user message's text — the child-run routing key.
String _lastUserText(Context context) {
  for (final message in context.messages.reversed) {
    if (message is UserMessage) return message.content as String;
  }
  return '';
}

/// A scripted stream: the parent replays [parentTurns] in order; a CHILD
/// run (its task carries the marker) replays a plain text turn.
final class _RegistryRouter {
  _RegistryRouter(this.parentTurns);

  final List<List<AssistantMessageEvent>> parentTurns;
  int _parentCalls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    if (_lastUserText(context).contains('KIDMARK')) {
      return FakeStreamFunction([textTurn('child done')]).call(
        model,
        context,
      );
    }
    final index =
        _parentCalls < parentTurns.length ? _parentCalls : parentTurns.length - 1;
    _parentCalls++;
    return FakeStreamFunction([parentTurns[index]]).call(model, context);
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
    final cli = await bootedCli(
      FakeStreamFunction([textTurn('')]).call,
    );
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
      try {
        await waitForIt(
          () => cli.subagentManager['kid'] != null,
          reason: 'the child registers',
        );
      } on Object {
        // ignore: avoid_print
        print('OUT TAIL: ${io.out.toString().substring(
              io.out.toString().length - 1500.clamp(0, io.out.toString().length),
            )}');
        rethrow;
      }
      await waitForIt(
        () => cli.subagentManager['kid']!.windowTokens == 478000,
        reason: 'the child pressure stamp resolves the registered window',
      );
    },
  );
}
