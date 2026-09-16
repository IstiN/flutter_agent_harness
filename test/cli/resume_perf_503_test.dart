/// Issue #503 perf contracts (owner live report, marathon session at
/// ctx ~84%): (a) a synthetic 500-message session incl. 50k-char tool
/// rows resumes fast and (b) an interactive keystroke repaint stays under
/// the 16ms frame cadence class. Hard gates are at the library level
/// (deterministic, no PTY/VM noise):
///
///   - the resume replay pipeline (buildReplayEntries + the first
///     transcript format the TUI's first frame runs) < 2s;
///   - one keystroke frame (FaTuiModel.view()) < 50ms.
///
/// RED on the pre-fix build: buildReplayEntries formats WHOLE messages
/// (50k rows fully split/styled), the backward budget walk formats
/// entries it will drop, and per-keystroke frames pay for history work
/// they never show.
library;

import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_replay.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

FaTuiModel _modelWithHistory(List<String> history) => FaTuiModel(
  callbacks: FaTuiCallbacks(
    onSubmit: (line, {images = const []}) async {},
    onModelSelected: (id) async {},
    buildSlashMenu: (prefix) => const [],
    buildModelMenu: (filter, width) => const [],
    statusLine: () => '/tmp/ws · ctx 5% · 0tok · turn 0 · openai/mock',
    prompt: 'fa> ',
  ),
  isExited: () => false,
  outputLines: history,
);

String _blob(int chars, {int newlineEvery = 120}) {
  final sb = StringBuffer();
  for (var i = 0; i < chars; i++) {
    sb.write(newlineEvery > 0 && i > 0 && i % newlineEvery == 0 ? '\n' : 'a');
  }
  return sb.toString();
}

/// Markdown-rich text the way a real marathon turn reads: prose, a fenced
/// block, a table, wide CJK runs.
String _richText(int lines) {
  final sb = StringBuffer();
  for (var i = 0; i < lines; i++) {
    sb.writeln(switch (i % 7) {
      0 => '## Section $i — 终处理 with **bold** and `inline code`',
      1 => '| col$i | value | a third column with longer text |',
      2 => '```dart',
      3 => 'final x$i = compute($i); // 注释 a wide comment run 終終終終',
      4 => '```',
      5 => '- bullet $i with a [link](https://example.com/$i) and more prose',
      _ => 'prose line $i with enough words to wrap at eighty columns a b c',
    });
  }
  return sb.toString();
}

/// The synthetic marathon session: 500+ messages, 50k-char tool rows.
List<Message> marathonMessages() {
  final messages = <Message>[];
  var t = DateTime.utc(2026, 1, 1);
  var turn = 0;
  for (var i = 0; i < 250; i++) {
    t = t.add(const Duration(seconds: 1));
    messages.add(UserMessage(content: _blob(300), timestamp: t));
    t = t.add(const Duration(seconds: 1));
    if (i % 5 == 4) {
      // A monster turn: 20k thinking, 50k file-dump text, 50k tool
      // arguments and a 50k result (every 5th of these an error).
      turn++;
      final failed = turn % 5 == 0;
      messages.add(
        AssistantMessage(
          content: [
            ThinkingContent(thinking: _richText(300) + _blob(20000)),
            TextContent(text: _richText(200) + _blob(50000)),
            ToolCall(
              id: 'c$i',
              name: 'bash',
              arguments: {'command': _blob(50000, newlineEvery: 0)},
            ),
          ],
          api: 'test',
          provider: 'test',
          model: 'm',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: t,
        ),
      );
      messages.add(
        ToolResultMessage(
          toolCallId: 'c$i',
          toolName: 'bash',
          content: [TextContent(text: _blob(50000))],
          isError: failed,
          timestamp: t,
        ),
      );
    } else {
      messages.add(
        AssistantMessage(
          content: [TextContent(text: _richText(10))],
          api: 'test',
          provider: 'test',
          model: 'm',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: t,
        ),
      );
    }
  }
  return messages;
}

void main() {
  test('resume replay pipeline stays under 2s on a marathon session', () {
    final messages = marathonMessages();
    expect(messages.length, greaterThanOrEqualTo(500));

    final sw = Stopwatch()..start();
    final (entries, _) = buildReplayEntries(
      messages,
      tui: true,
      width: 80,
      dim: (s) => '\x1b[2m$s\x1b[0m',
    );
    final replayMs = sw.elapsedMilliseconds;

    // The TUI's first frame formats the replayed transcript wholesale
    // (TranscriptMarkdown's cold path) — count it in the boot budget.
    sw
      ..reset()
      ..start();
    final tx = TranscriptMarkdown(width: 80);
    final lines = [for (final entry in entries) ...entry];
    tx.sync(lines);
    final firstFormatMs = sw.elapsedMilliseconds;

    // ignore: avoid_print
    print(
      'PERF resume pipeline: replay=${replayMs}ms '
      'firstFormat=${firstFormatMs}ms rows=${tx.wrappedRows.length} '
      'entries=${entries.length}',
    );
    expect(
      replayMs + firstFormatMs,
      lessThan(2000),
      reason: 'resume boot pipeline: replay=$replayMs '
          'firstFormat=$firstFormatMs',
    );
  });

  test('keystroke repaint stays under 50ms with a marathon transcript', () {
    final messages = marathonMessages();
    final (entries, _) = buildReplayEntries(
      messages,
      tui: true,
      width: 80,
      dim: (s) => '\x1b[2m$s\x1b[0m',
    );
    final lines = [for (final entry in entries) ...entry];
    var model = _modelWithHistory(lines);

    // Warm the wrap cache (the first frame after boot pays it once).
    model.view();
    final sw = Stopwatch();
    var worst = 0;
    var total = 0;
    const keystrokes = 20;
    for (var i = 0; i < keystrokes; i++) {
      model = model.setInputTextForTest('k' * (i + 1));
      sw
        ..reset()
        ..start();
      model.view();
      sw.stop();
      final ms = sw.elapsedMilliseconds;
      if (ms > worst) worst = ms;
      total += ms;
    }
    // ignore: avoid_print
    print(
      'PERF keystroke frame: worst=${worst}ms '
      'avg=${(total / keystrokes).toStringAsFixed(1)}ms',
    );
    expect(
      worst,
      lessThan(50),
      reason: 'keystroke repaint: worst=$worst avg=$total/$keystrokes',
    );
  });
}
