/// PTY-integration test hook (issue #446 AC1): `FA_TEST_STREAM_SCRIPT`
/// names a JSON file of scripted provider turns; when set, the CLI streams
/// those turns instead of dialing a real provider, so a PTY harness can run
/// a real live turn (real tool execution, real session records) with no
/// network. Test-only surface — never set in production boots.
///
/// Script shape: a JSON array of turns; each turn is an array of steps;
/// a step is `{"text": "..."}` (a streamed text block), `{"thinking":
/// "..."}` (a streamed reasoning block — gh-1197 AC2), `{"sleep_ms": N}`
/// (a pause with no model events — models a long tool gap), or
/// `{"tool_call": {"id": "...", "name": "...", "arguments": {...}}}`.
/// Text and thinking steps accept optional `"chunks": N` and `"pace_ms":
/// M` (default 1 chunk, no delay) to emit N paced deltas M ms apart, so a
/// PTY harness can watch the TUI paint DURING a multi-second stream
/// (gh-1197 AC1/AC2) instead of receiving the whole turn at once.
/// Turns are consumed in call order; the last turn repeats for any extra
/// provider calls (subagents share the process stream).
library;

import 'dart:async';
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
    // Paced turns keep pushing after this function returns (the consumer
    // pulls the stream meanwhile) — the scheduled pushes land on the
    // event loop like real network deltas.
    unawaited(_play(steps, model, stream));
    return stream;
  };
}

/// Pushes [steps]' events into [stream], honoring per-step pacing, then
/// ends the stream. Paced deltas model a real network stream: the TUI's
/// 16ms coalescer and the frame pump paint BETWEEN the pushes, which is
/// the whole point of the gh-1197 AC1/AC2 regression legs.
Future<void> _play(
  List<_Step> steps,
  Model model,
  AssistantMessageEventStream stream,
) async {
  try {
    for (final (event, delayMs) in _events(steps, model)) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      if (event != null) stream.push(event);
    }
  } on Object {
    // Consumer gone (test teardown) — nothing to push into.
  } finally {
    stream.end();
  }
}

/// One scripted step: a text block, a thinking block, a tool call, or a
/// bare pause.
class _Step {
  _Step(this.json);

  final Map<String, dynamic> json;

  String? get text => json['text'] as String?;
  String? get thinking => json['thinking'] as String?;
  int? get sleepMs => json['sleep_ms'] as int?;
  int get chunks => (json['chunks'] as int?) ?? 1;
  int get paceMs => (json['pace_ms'] as int?) ?? 0;
  Map<String, dynamic>? get toolCall =>
      json['tool_call'] as Map<String, dynamic>?;
}

/// Splits [body] into [chunks] paced pieces (at least one).
List<String> _pieces(String body, int chunks) {
  if (chunks <= 1 || body.isEmpty) return [body];
  final size = (body.length / chunks).ceil();
  return [
    for (var i = 0; i < body.length; i += size)
      body.substring(i, (i + size).clamp(0, body.length)),
  ];
}

/// Materializes one turn's events against the calling [model] — the same
/// event grammar the real adapters emit (start, per-block start/delta/end,
/// done). Text and thinking steps with `chunks`/`pace_ms` yield one delta
/// event per chunk, each paired with the pause that must precede its push;
/// tool calls stay unpaced (the sleep step models long gaps). A null
/// event is the sleep step's pure pause.
List<(AssistantMessageEvent?, int)> _events(List<_Step> steps, Model model) {
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
  final events = <(AssistantMessageEvent?, int)>[(StartEvent(partial: partial()), 0)];
  var contentIndex = 0;
  final blocks = <ContentBlock>[];
  var toolUse = false;
  for (final step in steps) {
    final text = step.text;
    final thinking = step.thinking;
    final call = step.toolCall;
    final sleepMs = step.sleepMs;
    if (sleepMs != null) {
      events.add((null, sleepMs));
      continue;
    }
    if (thinking != null) {
      var acc = '';
      blocks.add(const ThinkingContent(thinking: ''));
      events.add((
        ThinkingStartEvent(contentIndex: contentIndex, partial: partial()),
        0,
      ));
      for (final piece in _pieces(thinking, step.chunks)) {
        acc += piece;
        blocks[blocks.length - 1] = ThinkingContent(thinking: acc);
        events.add((
          ThinkingDeltaEvent(
            contentIndex: contentIndex,
            delta: piece,
            partial: partial(content: List.of(blocks)),
          ),
          step.paceMs,
        ));
      }
      events.add((
        ThinkingEndEvent(
          contentIndex: contentIndex,
          content: acc,
          partial: partial(content: List.of(blocks)),
        ),
        0,
      ));
      contentIndex++;
      continue;
    }
    if (text != null) {
      var acc = '';
      blocks.add(const TextContent(text: ''));
      events.add((TextStartEvent(contentIndex: contentIndex, partial: partial()), 0));
      for (final piece in _pieces(text, step.chunks)) {
        acc += piece;
        blocks[blocks.length - 1] = TextContent(text: acc);
        events.add((
          TextDeltaEvent(
            contentIndex: contentIndex,
            delta: piece,
            partial: partial(content: List.of(blocks)),
          ),
          step.paceMs,
        ));
      }
      events.add((
        TextEndEvent(
          contentIndex: contentIndex,
          content: acc,
          partial: partial(content: List.of(blocks)),
        ),
        0,
      ));
      contentIndex++;
      continue;
    }
    if (call != null) {
      toolUse = true;
      final block = ToolCall(
        id: call['id'] as String,
        name: call['name'] as String,
        arguments: (call['arguments'] as Map<String, dynamic>? ?? const {})
            .cast<String, dynamic>(),
      );
      blocks.add(block);
      events
        ..add((
          ToolCallStartEvent(contentIndex: contentIndex, partial: partial()),
          0,
        ))
        ..add((
          ToolCallEndEvent(
            contentIndex: contentIndex,
            toolCall: block,
            partial: partial(
              content: List.of(blocks),
              reason: StopReason.toolUse,
            ),
          ),
          0,
        ));
      contentIndex++;
    }
  }
  events.add((
    DoneEvent(
      reason: toolUse ? StopReason.toolUse : StopReason.stop,
      message: partial(
        content: blocks,
        reason: toolUse ? StopReason.toolUse : StopReason.stop,
      ),
    ),
    0,
  ));
  return events;
}
