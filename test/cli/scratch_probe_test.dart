/// Scratch probe: today's headless byte shape for interleaved turns.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  test('probe: headless interleaved byte order (styled surface)', () async {
    final io = FakeCliIO();
    const call = ToolCall(id: 't1', name: 'bash', arguments: {'command': 'echo hi'});
    final empty = testAssistant();
    final thinkingPartial = testAssistant(
      content: [ThinkingContent(thinking: 'pondering…')],
    );
    final textPartial = testAssistant(
      content: [
        ThinkingContent(thinking: 'pondering…'),
        TextContent(text: 'Checking the file now.'),
      ],
    );
    final toolPartial = testAssistant(
      content: [
        ThinkingContent(thinking: 'pondering…'),
        TextContent(text: 'Checking the file now.'),
        call,
      ],
      stopReason: StopReason.toolUse,
    );
    final turn1 = () => <AssistantMessageEvent>[
      StartEvent(partial: empty),
      ThinkingStartEvent(contentIndex: 0, partial: empty),
      ThinkingDeltaEvent(
        contentIndex: 0,
        delta: 'pondering…',
        partial: thinkingPartial,
      ),
      ThinkingEndEvent(contentIndex: 0, content: 'pondering…', partial: thinkingPartial),
      TextStartEvent(contentIndex: 1, partial: thinkingPartial),
      TextDeltaEvent(contentIndex: 1, delta: 'Checking the file now.', partial: textPartial),
      ToolCallStartEvent(contentIndex: 2, partial: textPartial),
      ToolCallEndEvent(contentIndex: 2, toolCall: call, partial: toolPartial),
      DoneEvent(reason: StopReason.toolUse, message: toolPartial),
    ];
    final turn2 = () => textTurn('All done — found it.');
    // Same-message trailing text: [text1, tool_use, text2] in ONE message.
    final trailingPartial = testAssistant(
      content: [
        ThinkingContent(thinking: 'pondering…'),
        TextContent(text: 'Checking the file now.'),
        call,
        TextContent(text: ' and cross-checking the output.'),
      ],
      stopReason: StopReason.toolUse,
    );
    final turn1b = () => <AssistantMessageEvent>[
      StartEvent(partial: empty),
      ThinkingStartEvent(contentIndex: 0, partial: empty),
      ThinkingDeltaEvent(
        contentIndex: 0,
        delta: 'pondering…',
        partial: thinkingPartial,
      ),
      ThinkingEndEvent(contentIndex: 0, content: 'pondering…', partial: thinkingPartial),
      TextStartEvent(contentIndex: 1, partial: thinkingPartial),
      TextDeltaEvent(contentIndex: 1, delta: 'Checking the file now.', partial: textPartial),
      ToolCallStartEvent(contentIndex: 2, partial: textPartial),
      ToolCallEndEvent(contentIndex: 2, toolCall: call, partial: toolPartial),
      TextStartEvent(contentIndex: 3, partial: toolPartial),
      TextDeltaEvent(
        contentIndex: 3,
        delta: ' and cross-checking the output.',
        partial: trailingPartial,
      ),
      DoneEvent(reason: StopReason.toolUse, message: trailingPartial),
    ];
    final fake = FakeStreamFunction([turn1b(), turn2()]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'sk-test',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
        headlessRun: true,
      ),
      io: io,
      markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
      streamFunction: fake.call,
    );
    await cli.runHeadless('probe');
    final out = io.out.toString();
    // ignore: avoid_print
    print('=== BEGIN ===');
    // ignore: avoid_print
    print(out.replaceAll('\x1B', '<ESC>'));
    // ignore: avoid_print
    print('=== END ===');
    final iText = out.indexOf('Checking the file now.');
    final iToolStart = out.indexOf('• bash');
    final iToolEnd = out.indexOf('✓ bash');
    final iTrailing = out.indexOf('All done — found it.');
    // ignore: avoid_print
    print('indexes: text=$iText toolStart=$iToolStart toolEnd=$iToolEnd '
        'trailing=$iTrailing dim=${out.contains('\x1B[2mpondering…\x1B[0m')}');
    expect(iText, greaterThanOrEqualTo(0));
    expect(iTrailing, greaterThanOrEqualTo(0));
  });
}
