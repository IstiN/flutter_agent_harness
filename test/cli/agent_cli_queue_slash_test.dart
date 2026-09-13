import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An immediately-ending stream: every call emits one text turn.
class _InstantStream {
  _InstantStream(this.text);

  final String text;
  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    final stream = AssistantMessageEventStream();
    stream
      ..push(StartEvent(partial: testAssistant()))
      ..push(
        DoneEvent(
          reason: StopReason.stop,
          message: testAssistant(content: [TextContent(text: text)]),
        ),
      )
      ..end();
    return stream;
  }
}

/// `/queue` slash coverage: help text without `clear`, and the no-TUI
/// guard for `clear` (an interactive TUI session is out of a UT's scope).
void main() {
  test(
    '/queue prints the queue hint; /queue clear without a TUI is a no-op',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final stream = _InstantStream('idle');
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 128000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      for (var i = 0; i < 5000 && stream.calls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      io.sendLine('/queue');
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('Queued messages render');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(io.out.toString(), contains('Queued messages render'));
      expect(io.out.toString(), contains('/queue clear'));
      io.sendLine('/queue clear');
      for (
        var i = 0;
        i < 5000 && !io.out.toString().contains('No interactive TUI session');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(io.out.toString(), contains('No interactive TUI session'));
      // Settle the REPL loop, then release the fake IO.
      io.sendLine('/exit');
      await run.timeout(const Duration(seconds: 30), onTimeout: () {});
      await io.close();
    },
  );
}
