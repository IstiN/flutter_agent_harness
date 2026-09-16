/// PTY-integration test hook (issue #446 AC1): `FA_TEST_STREAM_SCRIPT`
/// names a JSON file of scripted provider turns; when set, the CLI streams
/// those turns instead of dialing a real provider, so a PTY harness can run
/// a real live turn (real tool execution, real session records) with no
/// network. Test-only surface — never set in production boots.
///
/// Script shape: a JSON array of turns; each turn is an array of steps;
/// a step is `{"text": "..."}` (a streamed text block) or
/// `{"tool_call": {"id": "...", "name": "...", "arguments": {...}}}`.
/// Turns are consumed in call order; the last turn repeats for any extra
/// provider calls (subagents share the process stream).
library;

import 'dart:convert';
import 'dart:io' show File, Platform;

import '../agent/agent_loop.dart' show StreamFunction;
import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';

/// Returns the scripted stream function for the script at [path]
/// (defaulting to `FA_TEST_STREAM_SCRIPT`), else null so the boot path
/// stays untouched. The [path] parameter keeps the consumption contract
/// unit-testable; production boots never pass it.
StreamFunction? scriptedTestStreamFunction([String? path]) {
  path ??= Platform.environment['FA_TEST_STREAM_SCRIPT'];
  if (path == null || path.trim().isEmpty) return null;
  final raw = jsonDecode(File(path.trim()).readAsStringSync()) as List<dynamic>;
  final script = [
    for (final turn in raw)
      [
        for (final step in (turn as List<dynamic>))
          _Step((step as Map<String, dynamic>).cast<String, dynamic>()),
      ],
  ];
  var next = 0;
  return (Model model, Context context, {CancelToken? cancelToken}) {
    final steps = script[next < script.length ? next++ : script.length - 1];
    final stream = AssistantMessageEventStream();
    for (final event in _events(steps, model)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  };
}

/// One scripted step: a text block or a tool call.
class _Step {
  _Step(this.json);

  final Map<String, dynamic> json;

  String? get text => json['text'] as String?;
  Map<String, dynamic>? get toolCall =>
      json['tool_call'] as Map<String, dynamic>?;
}

/// Materializes one turn's events against the calling [model] — the same
/// event grammar the real adapters emit (start, per-block start/delta/end,
/// done).
List<AssistantMessageEvent> _events(List<_Step> steps, Model model) {
  AssistantMessage partial({
    List<ContentBlock> content = const [],
    StopReason reason = StopReason.stop,
  }) => AssistantMessage(
    content: content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: reason,
    timestamp: DateTime.now(),
  );
  final events = <AssistantMessageEvent>[StartEvent(partial: partial())];
  var contentIndex = 0;
  final blocks = <ContentBlock>[];
  var toolUse = false;
  for (final step in steps) {
    final text = step.text;
    final call = step.toolCall;
    if (text != null) {
      final block = TextContent(text: text);
      blocks.add(block);
      events
        ..add(TextStartEvent(contentIndex: contentIndex, partial: partial()))
        ..add(
          TextDeltaEvent(
            contentIndex: contentIndex,
            delta: text,
            partial: partial(content: List.of(blocks)),
          ),
        );
    } else if (call != null) {
      toolUse = true;
      final block = ToolCall(
        id: call['id'] as String,
        name: call['name'] as String,
        arguments: (call['arguments'] as Map<String, dynamic>? ?? const {})
            .cast<String, dynamic>(),
      );
      blocks.add(block);
      events
        ..add(
          ToolCallStartEvent(contentIndex: contentIndex, partial: partial()),
        )
        ..add(
          ToolCallEndEvent(
            contentIndex: contentIndex,
            toolCall: block,
            partial: partial(
              content: List.of(blocks),
              reason: StopReason.toolUse,
            ),
          ),
        );
    }
    contentIndex++;
  }
  events.add(
    DoneEvent(
      reason: toolUse ? StopReason.toolUse : StopReason.stop,
      message: partial(
        content: blocks,
        reason: toolUse ? StopReason.toolUse : StopReason.stop,
      ),
    ),
  );
  return events;
}
