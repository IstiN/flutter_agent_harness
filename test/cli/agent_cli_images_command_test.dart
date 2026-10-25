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

/// `/images` (issue #1889 AC4): the CLI surface renders the SHARED
/// projection — window counts + per-image detail after a capped request,
/// the quiet one-liner before one, and the kill-switch line when the
/// registry is disabled. Nothing floods: one report, one notice.
void main() {
  Future<(AgentCli, FakeCliIO, _InstantStream)> _boot({
    ImageRegistryConfig config = const ImageRegistryConfig(),
  }) async {
    final io = FakeCliIO();
    final stream = _InstantStream('idle');
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: stream.call,
    );
    imageRegistryConfig = config;
    unawaited(cli.run());
    for (var i = 0; i < 5000 && stream.calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return (cli, io, stream);
  }

  ImageDropReport report(int drops, int registry) => ImageDropReport(
    drops: [
      for (var i = 0; i < drops; i++)
        ImageDropEvent(index: i, key: 'content00$i', fromCurrentMessage: false),
    ],
    cap: 20,
    modelId: testModel.id,
    currentImageCount: 0,
    registryCount: registry,
    ridingCount: registry - drops,
  );

  Future<void> _pump(FakeCliIO io, String needle) async {
    for (var i = 0; i < 5000 && !io.out.toString().contains(needle); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  tearDown(() {
    imageDropReportNotice = null;
    imageRegistryConfig = const ImageRegistryConfig();
  });

  test(
    '/images renders the shared projection after a capped request',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (cli, io, stream) = await _boot();
      addTearDown(io.close);

      // Before any capped request: the quiet one-liner + knobs.
      io.sendLine('/images');
      await _pump(io, 'no capped request yet');
      expect(io.out.toString(), contains('cap: 20 per request for'));
      expect(io.out.toString(), contains('images.registry: false'));

      // One capped request report: ONE notice (not 17 lines).
      io.out.clear();
      imageDropReportNotice?.call(report(17, 37));
      final noticeLines = io.out
          .toString()
          .split('\n')
          .where((l) => l.contains('[images]'))
          .toList();
      expect(noticeLines, hasLength(1));
      expect(noticeLines.single, contains('17 older images not sent'));

      // /images now shows the window counts + the per-image detail.
      io.sendLine('/images');
      await _pump(io, '37 in the window, 20 sent, 17 not sent');
      expect(io.out.toString(), contains('dropped [Image 0]'));
    },
  );

  test(
    '/images under the kill switch renders the disabled line',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final (cli, io, stream) = await _boot(
        config: ImageRegistryConfig(enabled: false),
      );
      addTearDown(io.close);

      io.sendLine('/images');
      await _pump(io, 'registry disabled');
      expect(io.out.toString(), contains('no drops, no notices'));
    },
  );
}
