/// Issue #355 regression, layer 3: REAL dart:io HTTP stack (loopback
/// ServerSocket) serving a plain-JSON 403, through the REAL adapter, in
/// TUI mode. MockClient passes; the PTY lab wedges deterministically —
/// the remaining delta is the socket layer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:http/http.dart' as http;
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

void main() {
  test(
    'real-socket 403 in TUI mode: error painted, app alive, Ctrl+C quits (#355)',
    () async {
      // A real loopback server answering 403 + JSON error body — the exact
      // shape the gateway and the local PTY lab both served.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final port = server.port;
      server.listen((socket) {
        socket.listen((data) async {
          const body =
              '{"error":{"message":"forbidden: access denied",'
              '"type":"invalid_request_error"}}';
          socket.write(
            'HTTP/1.1 403 Forbidden\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n'
            'Connection: close\r\n\r\n$body',
          );
          await socket.flush();
          await socket.close();
        });
      });

      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final env = MemoryExecutionEnv(cwd: '/work');
      final io = FakeCliIO();
      final client = http.Client();
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

      final loopModel = Model(
        id: testModel.id,
        api: 'openai-completions',
        provider: testModel.provider,
        baseUrl: 'http://127.0.0.1:$port/v1',
        contextWindow: testModel.contextWindow,
        maxTokens: testModel.maxTokens,
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: loopModel,
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
            reason: 'the socket 403 must reach the TUI (#355)');
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
        client.close();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
