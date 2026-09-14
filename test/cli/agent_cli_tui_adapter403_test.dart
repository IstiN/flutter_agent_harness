/// Issue #355 regression, layer 2: the REAL openai-completions adapter
/// decoding an HTTP 403 (plain JSON error body, not SSE) in TUI mode.
/// The fake-stream variant (agent_cli_tui_error_wedge_test.dart) passes —
/// the PTY lab wedges deterministically against BOTH the real gateway and
/// a local 403 server, so the fault lives between the adapter's non-200
/// handling and the TUI run path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

http.Client _forbiddenClient() => MockClient.streaming(
      (request, requestBody) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            '{"error":{"message":"forbidden: access denied",'
            '"type":"invalid_request_error"}}',
          ),
        ),
        403,
        headers: const {'content-type': 'application/json'},
      ),
    );

void main() {
  test(
    'adapter-level 403 in TUI mode: error painted, app alive, Ctrl+C quits (#355)',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final client = _forbiddenClient();
      AssistantMessageEventStream realAdapter(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        return streamOpenAICompletions(
          model,
          context,
          OpenAICompletionsOptions(cancelToken: cancelToken),
          client,
        );
      }

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
        streamFunction: realAdapter,
      );
      final run = cli.run();
      try {
        await waitForIt(() => frames.text.contains('\x1b[?1049h'));
        keys.add(utf8.encode('hi'));
        keys.add([0x0d]);
        var painted = false;
        for (var i = 0; i < 2400 && !painted; i++) {
          painted = frames.text.contains('403') ||
              frames.text.contains('forbidden');
          if (!painted) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }
        expect(painted, isTrue,
            reason: 'the adapter 403 must reach the TUI (#355)');
        var exited = false;
        run.then((_) => exited = true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(exited, isFalse,
            reason: 'a run error must never exit the TUI app (#355)');
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
