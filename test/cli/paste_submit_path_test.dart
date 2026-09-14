/// The composer-chip submit path end-to-end at the CLI level (issue #276):
/// a TUI submit carrying clipboard chips reaches the provider context as
/// ImageContent blocks next to the text — both when the CLI is idle (a new
/// prompt) and mid-run (steering).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/paste_image.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final _chip = TuiImageAttachment(
  name: 'clipboard-1.png',
  mimeType: 'image/png',
  bytes: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
);

/// A stream function that blocks one chosen call on a gate (same shape as
/// the busy-steering test's helper): holds a run open so the mid-run steer
/// is deterministic.
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(
        gate.future.then((_) => emit(turns.removeAt(0))),
      );
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// Waits for the CLI to persist its session (boot complete).
Future<void> _waitForSessions(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

void main() {
  test(
    'an idle TUI submit with chips prompts with ImageContent blocks',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([textTurn('seen the image')], gateOnCall: -1);
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await _waitForSessions(env);

      await cli.tuiSubmitForTest('look at this', [_chip]);
      await waitForIt(() => stream.calls >= 1 && !cli.isBusy);

      final message = stream.contexts.last.messages.last as UserMessage;
      final blocks = message.content as List<ContentBlock>;
      expect(
        blocks.whereType<TextContent>().map((b) => b.text).join(' '),
        contains('look at this'),
      );
      final images = blocks.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.single.data, base64Encode(_chip.bytes));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a mid-run TUI submit with chips steers ImageContent blocks',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await _waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      cli.steerImagesForTest('look at this mid-run', [_chip]);
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'first run settles');

      // The steered turn carries the image next to the text.
      final message = stream.contexts[1].messages.last as UserMessage;
      final blocks = message.content as List<ContentBlock>;
      expect(
        blocks.whereType<TextContent>().map((b) => b.text).join(' '),
        contains('look at this mid-run'),
      );
      expect(
        blocks.whereType<ImageContent>().map((b) => b.mimeType),
        contains('image/png'),
      );

      io.sendLine('/exit');
      await run;
    },
  );
}
