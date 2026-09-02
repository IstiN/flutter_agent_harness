import 'package:flutter_agent_harness/src/cli/tui_replay.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart'
    show
        branchSummaryPrefix,
        branchSummarySuffix,
        compactionSummaryPrefix,
        compactionSummarySuffix;
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

void main() {
  String dim(String text) => '<d>$text</d>';

  AssistantMessage assistant(List<ContentBlock> content) => AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );

  group('system-notice replay', () {
    const settleNotice =
        '<system-notice>\n'
        'Background shell job sh-32-hlrc finished with exit code 0.\n'
        'Command: git commit -m "fix(provider): entry-name status label\n'
        '  plus a very long multi-line commit body full of noise"\n'
        'Log: /tmp/x/.fah/bash_jobs/sh-32-hlrc.log\n'
        'Check the result with bash_job (action: output) or by reading the\n'
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>';

    test('a settled background-job notice replays as ONE dim chrome line', () {
      final lines = replayLinesTui(
        UserMessage.text(settleNotice),
        width: 80,
        dim: dim,
      );
      expect(lines, [
        '<d>${'─' * 80}</d>',
        '<d>⚙ Background shell job sh-32-hlrc finished with exit code 0.</d>',
        '',
      ]);
    });

    test('the notice never leaks the closing tag or the command dump', () {
      final lines = replayLines(UserMessage.text(settleNotice), maxRows: 0);
      expect(lines, hasLength(1));
      expect(lines.single, contains('⚙'));
      expect(lines.single, isNot(contains('system-notice')));
      expect(lines.single, isNot(contains('Command:')));
      expect(lines.single, isNot(contains('git commit')));
    });

    test('a one-line mail notice keeps its sentence', () {
      const mail =
          '<system-notice>New inter-agent mail arrived (2 message(s))'
          ' — read it with agent_directory.</system-notice>';
      final lines = replayLinesTui(UserMessage.text(mail), width: 80, dim: dim);
      expect(lines[1], contains('New inter-agent mail arrived'));
    });

    test('mixed content replays verbatim (not a notice)', () {
      final lines = replayLinesTui(
        UserMessage.text('look: <system-notice>x</system-notice>'),
        width: 80,
        dim: dim,
      );
      expect(lines.join(), contains('look:'));
    });
  });

  group('replayLinesTui', () {
    test('a plain-text user message renders as the background echo box', () {
      final lines = replayLinesTui(
        UserMessage.text('hello\nworld'),
        width: 10,
        dim: dim,
      );
      expect(lines, [
        '<d>──────────</d>',
        '\x1b[48;2;30;34;42mhello\x1b[0m',
        '\x1b[48;2;30;34;42mworld\x1b[0m',
        '',
      ]);
    });

    test('a block-content user message joins its text blocks', () {
      final lines = replayLinesTui(
        UserMessage(
          content: const [
            TextContent(text: 'a'),
            TextContent(text: 'b'),
          ],
          timestamp: DateTime.utc(2026),
        ),
        width: 4,
        dim: dim,
      );
      expect(lines[1], '\x1b[48;2;30;34;42ma\x1b[0m');
      expect(lines[2], '\x1b[48;2;30;34;42mb\x1b[0m');
    });

    test('an empty user message renders nothing', () {
      expect(
        replayLinesTui(UserMessage.text('   '), width: 10, dim: dim),
        isEmpty,
      );
    });

    test('assistant text plus tool calls ends with a dim indicator row', () {
      final lines = replayLinesTui(
        assistant(const [
          TextContent(text: 'answer'),
          ToolCall(id: '1', name: 'read', arguments: {}),
          ToolCall(id: '2', name: 'bash', arguments: {}),
        ]),
        width: 10,
        dim: dim,
      );
      expect(lines, ['answer', '<d>[read] [bash]</d>']);
    });

    test('assistant text replays IN FULL — no per-message head cap', () {
      final text = [for (var i = 1; i <= 25; i++) 'row $i'].join('\n');
      final lines = replayLinesTui(
        assistant([TextContent(text: text)]),
        width: 10,
        dim: dim,
      );
      // Every row survives the restore; nothing is hidden behind ' …'.
      expect(lines, hasLength(25));
      expect(lines.last, 'row 25');
      expect(lines.join('\n'), isNot(contains('…')));
    });

    test('an assistant message without text renders nothing', () {
      expect(
        replayLinesTui(
          assistant(const [ToolCall(id: '1', name: 'read', arguments: {})]),
          width: 10,
          dim: dim,
        ),
        isEmpty,
      );
    });

    test('tool results never render', () {
      expect(
        replayLinesTui(
          ToolResultMessage(
            toolCallId: '1',
            toolName: 'read',
            content: const [],
            isError: false,
            timestamp: DateTime.utc(2026),
          ),
          width: 10,
          dim: dim,
        ),
        isEmpty,
      );
    });

    test('a compaction summary renders as one compact marker row', () {
      final summary =
          '$compactionSummaryPrefix'
          'Implemented the login flow and fixed the token refresh.\n\n'
          '<read-files>\n/a.dart\n/b.dart\n</read-files>'
          '$compactionSummarySuffix';
      final lines = replayLinesTui(
        UserMessage.text(summary),
        width: 80,
        dim: dim,
      );
      expect(lines, hasLength(3));
      expect(lines[1], contains('context compacted into a summary'));
      expect(lines[1], contains('Implemented the login flow'));
      // The raw XML-ish block never leaks into the history.
      expect(lines.join('\n'), isNot(contains('<read-files>')));
      expect(lines.join('\n'), isNot(contains('</summary>')));
    });

    test('a branch summary renders compact too', () {
      final summary =
          '$branchSummaryPrefix'
          'The detour explored X.\n'
          '$branchSummarySuffix';
      final lines = replayLinesTui(
        UserMessage.text(summary),
        width: 80,
        dim: dim,
      );
      expect(lines[1], contains('summary of the detour branch'));
      expect(lines[1], contains('The detour explored X.'));
    });

    test('the marker row is truncated to the terminal width', () {
      final summary =
          '$compactionSummaryPrefix'
          '${'very long line ' * 20}'
          '$compactionSummarySuffix';
      final lines = replayLinesTui(
        UserMessage.text(summary),
        width: 40,
        dim: dim,
      );
      // dim() wraps in <d></d>; the visible text stays within 40 cols.
      final visible = lines[1].replaceAll('<d>', '').replaceAll('</d>', '');
      expect(visible.length, 40);
      expect(visible, endsWith('…'));
    });

    test('a long fenced message replays intact, fence balanced', () {
      // 26 rows with the fence opened at row 2 and closed near the end:
      // full replay keeps every row so the fence closes NATURALLY — and a
      // mid-fence budget cut between messages is still balanced by the
      // synthetic opener tested below.
      final body = [
        'intro',
        '```dart',
        for (var i = 0; i < 22; i++) 'line $i',
        '```',
        'after',
      ].join('\n');
      final lines = replayLinesTui(
        assistant([TextContent(text: body)]),
        width: 40,
        dim: dim,
      );
      expect(lines, hasLength(26));
      expect(lines.last, 'after');
    });

    test('a budget cut starting mid-fence prepends a balancing fence', () {
      final messages = [
        assistant([TextContent(text: '```\ncode\n```\nafter')]),
        assistant([TextContent(text: 'recent answer')]),
      ];
      // Budget admits only the last entry: the kept region is fence-balanced
      // here (no synthetic fence needed).
      var (entries, _) = buildReplayEntries(
        messages,
        tui: true,
        width: 40,
        dim: dim,
        rowBudget: 10,
      );
      expect(entries.first, isNot(['```']));

      // Now the fence OPENS in the dropped head and closes inside the kept
      // region: without the synthetic opener the closer would toggle state
      // ON and swallow the rest.
      final midCut = [
        assistant([TextContent(text: '```\nlong code block')]),
        assistant([TextContent(text: '```\nafter the block')]),
      ];
      (entries, _) = buildReplayEntries(
        midCut,
        tui: true,
        width: 40,
        dim: dim,
        rowBudget: 2,
      );
      expect(entries.first, ['```']);
    });
  });
}
