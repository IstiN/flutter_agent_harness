import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/continuation_notice.dart';
import 'package:test/test.dart';

/// Issue #438 AC4 — the continuation notice names what a fold hid: record
/// kinds + turn span per hidden range, with a `compact_expand` hint. E4:
/// long span lists cap to first/last; the full list stays in the session
/// file. AC5: no hidden ranges → empty line, the notice stays as it was.
void main() {
  MessageRecord messageRecord(String id, Message message) => MessageRecord(
    id: id,
    parentId: null,
    timestamp: DateTime.utc(2026),
    message: message,
  );

  HiddenRangeRecord hiddenRange(String id, List<String> recordIds) =>
      HiddenRangeRecord(
        id: id,
        parentId: null,
        timestamp: DateTime.utc(2026),
        recordIds: recordIds,
      );

  test('notice names hidden spans with kinds and the expand hint', () {
    final entries = <SessionRecord>[
      messageRecord('r1', UserMessage.text('fix the login crash')),
      messageRecord(
        'r2',
        AssistantMessage(
          content: [TextContent(text: 'step')],
          api: 'a',
          provider: 'p',
          model: 'm1',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      ),
      messageRecord(
        'r3',
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'read',
          content: [TextContent(text: 'payload')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ),
      hiddenRange('h1', ['r1', 'r2', 'r3']),
      messageRecord('r4', UserMessage.text('continue')),
    ];

    final line = hiddenRecoverablesSummary(entries);

    expect(line, contains('compact_expand'));
    expect(line, contains('records 2–4'));
    expect(line, contains('user×1'));
    expect(line, contains('assistant×1'));
    expect(line, contains('tool_result×1'));
  });

  test('E4: long span lists cap to first and last with the full-list hint', () {
    final entries = <SessionRecord>[
      for (var i = 1; i <= 15; i++)
        messageRecord('r$i', UserMessage.text('m$i')),
      for (var h = 1; h <= 5; h++)
        hiddenRange('h$h', ['r${h * 3 - 2}', 'r${h * 3 - 1}', 'r${h * 3}']),
    ];

    final line = hiddenRecoverablesSummary(entries, maxSpans: 3);

    // First and last spans shown, the middle ones collapsed.
    expect(line, contains('records 2–4'));
    expect(line, contains('records 14–16'));
    expect(line, isNot(contains('records 8–10')));
    expect(line, contains('+2 more'));
    expect(line, contains('session file'));
  });

  test('AC5: no hidden ranges — the recoverables line is empty', () {
    final entries = <SessionRecord>[
      messageRecord('r1', UserMessage.text('fix the login crash')),
    ];

    expect(hiddenRecoverablesSummary(entries), isEmpty);
  });
}
