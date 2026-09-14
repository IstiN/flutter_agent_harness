/// Issue #355 regression: a provider request failing fast (HTTP 403) must
/// never wedge the TUI. Repro (deterministic, 4/4 in the PTY lab): resume a
/// session, submit, the provider stream terminates with an [ErrorEvent] —
/// the error assistant record persists, but the turn never completes: the
/// spinner paints forever at ~0% CPU and Ctrl+C is ignored until the
/// process is SIGKILLed. Stochastic sibling fate: the whole app exits with
/// the resume hint instead of returning to the composer.
///
/// This boots the REAL AgentCli in TUI mode headlessly (same harness as
/// agent_cli_tui_sync_test.dart) and drives it with a provider that errors
/// instantly.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);
  void add(List<int> data) => _bytes.add(data);
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

/// Streams exactly one terminal [ErrorEvent] — a fast 403.
class _ErroringStreamFunction {
  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: AssistantMessage(
          content: const [],
          api: 'openai-completions',
          provider: 'openai',
          model: 'glm-5.3',
          usage: Usage.zero,
          stopReason: StopReason.error,
          errorMessage: '403: forbidden: access denied',
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    stream.end();
    return stream;
  }
}

void main() {
  test(
    'fast provider error in TUI mode: error painted, app alive, Ctrl+C quits (#355)',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            width: 80,
            height: 24,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: _ErroringStreamFunction().call,
      );
      final run = cli.run();
      try {
        await waitForIt(() => frames.text.contains('\x1b[?1049h'));
        // Submit a prompt: the provider errors instantly with a 403.
        keys.add(utf8.encode('hi'));
        keys.add([0x0d]);
        // The error must be painted within a bounded window.
        var painted = false;
        for (var i = 0; i < 2000 && !painted; i++) {
          painted = frames.text.contains('403');
          if (!painted) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        expect(painted, isTrue,
            reason: 'the provider error must reach the TUI (#355)');
        // The app must still be alive: the run future not completed.
        var exited = false;
        run.then((_) => exited = true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(exited, isFalse,
            reason: 'a run error must never exit the TUI app (#355)');
        // Ctrl+C must still quit cleanly — no wedge.
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10));
      } finally {
        await io.close();
        await keys.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
