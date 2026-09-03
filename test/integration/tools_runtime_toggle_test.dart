/// Runtime toggle behavior (issue #19 AC10–AC12, fakes only):
///
/// - AC10/AC11: `/tools disable X` removes X from the next model turn's
///   tool surface; calls to it return a plain tombstone (no throw) and the
///   turn completes; `/tools enable` restores.
/// - AC12: the system prompt stays byte-identical across the toggle — the
///   diff lives in `Context.tools` and is exactly the disabled tool's
///   schema entries. The sqlite variant swap changes the `read` schema by
///   exactly the SQLite paragraph (byte-checked against
///   [readSqliteSectionPrompt]).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show readSqliteSectionPrompt;
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// Trivial engine: the variant swap never opens a database.
class _UnusedSqliteEngine implements SqliteEngine {
  @override
  SqliteDatabase openReadOnly(String path) =>
      throw UnimplementedError('never opened');
}

/// [StreamFunction] that records the full [Context] of every model call and
/// answers plain text.
class _RecordingStream {
  final contexts = <Context>[];

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
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: testAssistant(content: [TextContent(text: 'ok')]),
      ),
    );
    stream.end();
    return stream;
  }

  List<Tool> toolsOf(int index) => contexts[index].tools ?? const <Tool>[];

  Set<String> toolNames(int index) =>
      toolsOf(index).map((tool) => tool.name).toSet();
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  Future<(AgentCli, _RecordingStream)> boot() async {
    final recorder = _RecordingStream();
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        webSearchConfig: WebSearchConfig(),
        sqliteEngine: _UnusedSqliteEngine(),
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: recorder.call,
    );
    return (cli, recorder);
  }

  /// Local poller: waits for a NEW occurrence of [expected] (the string
  /// may already be in the transcript from an earlier command).
  Future<void> settle(String line, String expected) async {
    int count(String out) => expected.allMatches(out).length;
    final before = count(io.out.toString());
    io.sendLine(line);
    for (var i = 0; i < 300; i++) {
      if (count(io.out.toString()) > before) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for: $expected');
  }

  test(
    'disable/enable toggles the tool surface without touching the prompt',
    () async {
      final (cli, recorder) = await boot();
      final run = cli.run();

      io.sendLine('turn one');
      await waitForIt(() => recorder.contexts.isNotEmpty);
      expect(recorder.toolNames(0), contains('web_search'));

      await settle('/tools disable web_search', 'disabled web_search');

      io.sendLine('turn two');
      await waitForIt(() => recorder.contexts.length >= 2);
      // AC12: prompt byte-identical, tools diff exactly the disabled tool.
      expect(
        recorder.contexts[1].systemPrompt,
        recorder.contexts[0].systemPrompt,
      );
      final before = recorder.toolNames(0);
      final after = recorder.toolNames(1);
      // `web_search` is a family id: both tools leave the surface together.
      expect(before.difference(after), {'web_search', 'web_fetch'});
      expect(after.difference(before), isEmpty);

      // AC10: a call to the disabled tool returns the tombstone, no throw.
      final result = await cli.agent.toolExecutor(
        ToolCall(id: 't1', name: 'web_search', arguments: const {}),
        null,
        null,
      );
      final tombstone = result.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      expect(tombstone, contains('disabled'));
      expect(tombstone, contains('ask the user to enable'));

      // AC11: enable restores the tool.
      await settle('/tools enable web_search', 'enabled web_search');
      io.sendLine('turn three');
      await waitForIt(() => recorder.contexts.length >= 3);
      expect(recorder.toolNames(2), contains('web_search'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'toggling sqlite swaps the read description by exactly the section',
    () async {
      final (cli, recorder) = await boot();
      final run = cli.run();

      io.sendLine('turn one');
      await waitForIt(() => recorder.contexts.isNotEmpty);
      final readOn = recorder
          .toolsOf(0)
          .firstWhere((tool) => tool.name == 'read');
      expect(readOn.description, contains('## SQLite databases'));

      await settle('/tools disable sqlite', 'disabled sqlite');

      io.sendLine('turn two');
      await waitForIt(() => recorder.contexts.length >= 2);
      final readOff = recorder
          .toolsOf(1)
          .firstWhere((tool) => tool.name == 'read');
      // Byte-exact: the enabled description minus the gated section (the
      // section plus its trailing blank separation) equals the disabled one.
      expect(
        readOff.description,
        readOn.description.replaceFirst('$readSqliteSectionPrompt\n\n', ''),
      );

      io.sendLine('/exit');
      await run;
    },
  );
}
