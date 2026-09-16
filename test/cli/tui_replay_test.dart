import 'dart:io';

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/system_notice_render.dart';
import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
import 'package:flutter_agent_harness/src/cli/tui_replay.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
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

  ToolResultMessage okResult(String callId, String text) => ToolResultMessage(
    toolCallId: callId,
    toolName: 'bash',
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );

  /// The live end row for [call] — the exact builder the streaming path
  /// paints in `_onToolExecutionEnd`, minus the live duration (replay shows
  /// the honest `—`). The replay row must equal this byte for byte.
  String liveEndRow(
    ToolCall call,
    ToolResultMessage? result, {
    int width = 80,
  }) {
    final failed = result == null || result.isError;
    var detail = toolRowDetail(call.name, call.arguments);
    var glyphPaint = tuiAccentSoft;
    var detailPaint = tuiDim;
    if (result != null && result.isError) {
      glyphPaint = tuiError;
      detailPaint = (s) => s;
      detail = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join()
          .split('\n')
          .first;
    }
    return layoutToolRow(
      ToolRowSegments(
        glyph: failed ? '✗' : '✓',
        label: call.name,
        detail: detail,
        elapsed: '—',
      ),
      width,
    ).style(glyph: glyphPaint, label: tuiAccent2, dim: detailPaint);
  }

  group('replay tool rows (issue #446 AC2)', () {
    final call = ToolCall(
      id: 'c1',
      name: 'bash',
      arguments: {'command': 'git status --short'},
    );

    test('a persisted call with its result renders through the live tool-row '
        'builder — never an [name] marker', () {
      final result = okResult('c1', 'M lib/a.dart\n');
      final lines = replayLinesTui(
        assistant([call]),
        width: 80,
        dim: dim,
        results: {'c1': result},
      );
      expect(lines, [liveEndRow(call, result)]);
      expect(lines.join(), isNot(contains('[bash]')));
      expect(lines.single, contains('✓'));
      expect(lines.single, contains('bash'));
      // Honest lossy bit: the settled replay row shows no live duration.
      expect(lines.single, contains('—'));
    });

    test('the args preview is the human detail (command text), not JSON', () {
      final lines = replayLinesTui(
        assistant([call]),
        width: 80,
        dim: dim,
        results: {'c1': okResult('c1', 'ok')},
      );
      expect(lines.single, contains('git status --short'));
      expect(lines.single, isNot(contains('{')));
    });

    test('an error result renders the ✗ row with the failure first line', () {
      final result = ToolResultMessage(
        toolCallId: 'c1',
        toolName: 'bash',
        content: [TextContent(text: 'fatal: not a repo\nstack')],
        isError: true,
        timestamp: DateTime.utc(2026),
      );
      final lines = replayLinesTui(
        assistant([call]),
        width: 80,
        dim: dim,
        results: {'c1': result},
      );
      expect(lines, [liveEndRow(call, result)]);
      expect(lines.single, contains('✗'));
      expect(lines.single, contains('fatal: not a repo'));
    });

    test('E1: a call missing its result renders interrupted — never bare', () {
      final lines = replayLinesTui(assistant([call]), width: 80, dim: dim);
      expect(lines, [liveEndRow(call, null)]);
      expect(lines.single, contains('✗'));
      expect(lines.join(), isNot(contains('[bash]')));
    });

    test('line mode renders the same grammar unpainted', () {
      final lines = replayLines(
        assistant([call]),
        maxRows: 0,
        results: {'c1': okResult('c1', 'ok')},
      );
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('fa:  '));
      expect(lines.single, contains('✓ bash'));
      expect(lines.single, contains('git status --short'));
      expect(lines.join(), isNot(contains('[bash]')));
    });
  });

  group('replay system rows (issue #446 AC3)', () {
    const settleNotice =
        '<system-notice>\n'
        'Background shell job sh-32-hlrc finished with exit code 0.\n'
        'Command: git commit -m "fix(provider): entry-name status label\n'
        '  plus a very long multi-line commit body full of noise"\n'
        'Log: /tmp/x/.fah/bash_jobs/sh-32-hlrc.log\n'
        'Check the result with bash_job (action: output) or by reading the\n'
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>';

    test('a settled background-job notice replays through the system-row '
        'renderer, exactly the live blockquote shape', () {
      final lines = replayLinesTui(
        UserMessage.text(settleNotice),
        width: 80,
        dim: dim,
      );
      expect(lines, renderSystemNoticeLines(settleNotice));
    });

    test(
      'zero literal ⚙-prefixed raw lines — every gear rides a blockquote',
      () {
        final lines = replayLinesTui(
          UserMessage.text(settleNotice),
          width: 80,
          dim: dim,
        );
        expect(lines.join('\n'), contains('⚙'));
        for (final line in lines) {
          if (line.replaceAll('\x1b[0m', '').contains('⚙')) {
            expect(
              line.trimLeft().startsWith('>'),
              isTrue,
              reason: 'raw gear line leaked: $line',
            );
          }
        }
      },
    );

    test('line mode rides the same renderer', () {
      final lines = replayLines(UserMessage.text(settleNotice), maxRows: 0);
      expect(lines, renderSystemNoticeLines(settleNotice));
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

  group('restoredInputHistory', () {
    test('collects plain user messages, skipping commands and chrome', () {
      final messages = [
        UserMessage.text('first question'),
        assistant([TextContent(text: 'the answer')]),
        UserMessage.text('/resume'),
        UserMessage.text('!ls -la'),
        UserMessage.text('   '),
        assistant([ToolCall(id: 't1', name: 'read', arguments: {})]),
        UserMessage.text('duplicated'),
        UserMessage.text('duplicated'),
      ];
      expect(restoredInputHistory(messages), ['first question', 'duplicated']);
    });

    test('system notices and compaction summaries are not history', () {
      const notice = '<system-notice>job sh-1 finished</system-notice>';
      final messages = [
        UserMessage.text(notice),
        UserMessage.text('$compactionSummaryPrefix<span>summary</span>'),
        UserMessage.text('a real message'),
      ];
      expect(restoredInputHistory(messages), ['a real message']);
    });

    test('keeps only the last 100 entries', () {
      final messages = [for (var i = 0; i < 120; i++) UserMessage.text('m$i')];
      final history = restoredInputHistory(messages);
      expect(history, hasLength(100));
      expect(history.first, 'm20');
      expect(history.last, 'm119');
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

    test('an empty user message renders nothing', () {
      expect(
        replayLinesTui(UserMessage.text('   '), width: 10, dim: dim),
        isEmpty,
      );
    });

    test('markdown parity (AC4): replayed text is the same raw markdown the '
        'live stream buffers — the view styles both identically', () {
      const text =
          'intro\n\n# Title\n\n- a\n2. two\n\n**bold** and '
          '`code`';
      final replayRows = replayLinesTui(
        assistant([TextContent(text: text)]),
        width: 80,
        dim: dim,
      );
      final liveRows = [
        '${assistantStreamPrefix()}intro',
        '',
        '# Title',
        '',
        '- a',
        '2. two',
        '',
        '**bold** and `code`',
      ];
      // Identical raw rows: whatever AnsiMarkdown does to one it does to
      // the other — same styled segments, same structure, zero dim SGR on
      // text rows (dim rides thinking only, exactly like live).
      expect(replayRows, liveRows);
      expect(replayRows.join('\n'), isNot(contains('\x1b[2m')));
      final styledReplay = AnsiMarkdown(width: 80);
      final styledLive = AnsiMarkdown(width: 80);
      final replayOut = [
        for (final row in replayRows) styledReplay.formatLine(row),
      ].join('\n');
      final liveOut = [
        for (final row in liveRows) styledLive.formatLine(row),
      ].join('\n');
      expect(replayOut, liveOut);
      expect(replayOut, contains('Title')); // heading marker consumed
      expect(replayOut, isNot(contains('# Title')));
      expect(replayOut, contains('\x1b[1mbold\x1b[0m'));
    });

    test('dim rides thinking rows only — never assistant text', () {
      final rows = replayLinesTui(
        assistant([
          ThinkingContent(thinking: 'reasoning hard\nline two'),
          TextContent(text: 'the answer'),
        ]),
        width: 80,
        dim: dim,
      );
      expect(rows, [
        '<d>reasoning hard</d>',
        '<d>line two</d>',
        '${assistantStreamPrefix()}the answer',
      ]);
    });

    test('the `>_Fa ` prefix lands on the first text row only', () {
      final rows = replayLinesTui(
        assistant([TextContent(text: 'one\ntwo')]),
        width: 80,
        dim: dim,
      );
      expect(rows.first, contains('>_'));
      expect(rows.first, contains('Fa'));
      expect(rows.first, contains('one'));
      expect(rows[1], 'two');
      expect(rows.skip(1).join(), isNot(contains('Fa ')));
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

    test('an assistant message without text renders its tool rows only', () {
      final call = ToolCall(
        id: 'c1',
        name: 'read',
        arguments: {'path': '/tmp/a.dart'},
      );
      final lines = replayLinesTui(
        assistant([call]),
        width: 80,
        dim: dim,
        results: {'c1': okResult('c1', 'ok')},
      );
      expect(lines, [liveEndRow(call, okResult('c1', 'ok'))]);
    });

    test('tool results never render standalone', () {
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

    test('a budget cut keeps whole messages and renders tool rows', () {
      final call = ToolCall(
        id: 'c9',
        name: 'bash',
        arguments: {'command': 'echo hi'},
      );
      final old = [
        UserMessage.text('old question'),
        assistant([TextContent(text: 'old answer')]),
      ];
      final recent = [
        UserMessage.text('new question'),
        assistant([call, TextContent(text: 'new answer')]),
        okResult('c9', 'hi'),
      ];
      final (entries, firstIndex) = buildReplayEntries(
        [...old, ...recent],
        tui: true,
        width: 80,
        dim: dim,
        rowBudget: 4,
      );
      expect(entries.join('\n'), contains('new answer'));
      expect(entries.join('\n'), contains('echo hi'));
      expect(entries.join('\n'), isNot(contains('old question')));
      expect(entries.join('\n'), isNot(contains('old answer')));
      expect(entries.join('\n'), isNot(contains('new question')));
      expect(firstIndex, 3);
    });
  });

  group('resume golden (issue #446 AC5)', () {
    test('the restored transcript pins the unified pipeline, shared with the '
        'live builder fixtures', () {
      final call = ToolCall(
        id: 'g1',
        name: 'bash',
        arguments: {'command': 'gh run cancel 123'},
      );
      final read = ToolCall(
        id: 'g2',
        name: 'read',
        arguments: {'path': 'lib/a.dart'},
      );
      const notice =
          '<system-notice>\n'
          'Background shell job sh-9 finished with exit code 0.\n'
          '</system-notice>';
      final results = {
        'g1': okResult('g1', 'cancelled'),
        'g2': okResult('g2', 'contents'),
      };
      final messages = [
        UserMessage.text('ship it'),
        assistant([
          TextContent(text: '# Plan\n\n- cancel the run\n- **verify**'),
          call,
          read,
        ]),
        okResult('g1', 'cancelled'),
        okResult('g2', 'contents'),
        UserMessage.text(notice),
        assistant([TextContent(text: 'done — the run is cancelled')]),
      ];
      final (entries, _) = buildReplayEntries(
        messages,
        tui: true,
        width: 80,
        dim: dim,
      );
      // SGR-stripped transcript: pins the grammar, not the palette.
      String strip(String s) => s.replaceAll(AnsiMarkdown.ansiSgrPattern, '');
      final transcript = [
        for (final entry in entries) ...[for (final line in entry) strip(line)],
      ];
      // The live builder produces the very same rows for the same records.
      expect(transcript, contains(strip(liveEndRow(call, results['g1']!))));
      expect(transcript, contains(strip(liveEndRow(read, results['g2']!))));
      expect(
        transcript,
        containsAll(renderSystemNoticeLines(notice).map(strip)),
      );
      expect(transcript.join('\n'), isNot(contains('[bash]')));
      expect(transcript.join('\n'), isNot(contains('[read]')));

      final file = File('test/cli/goldens/tui_resume.ans');
      final rendered = '${transcript.join('\n')}\n';
      if (Platform.environment.containsKey('FA_UPDATE_RESUME_GOLDENS')) {
        file.writeAsStringSync(rendered);
        return;
      }
      expect(rendered, file.readAsStringSync());
    });
  });
}
