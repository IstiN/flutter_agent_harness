// The deterministic `fake:` provider used by CI (AC2/AC6) — a scripted
// stream function with NO network and NO web-only imports, so it is both
// dart2js-compileable for the service worker and unit-testable on the VM.
//
// Script (test seam, AC2/AC3):
//   * user prompt containing "navigate <url>" → echo text + one
//     `browser_navigate` tool call, then DoneEvent(toolUse).
//   * a steering mail shaped "[from <sender>] dm <text>" → one `dap_dm`
//     tool call replying to the sender (deterministic E2E DM seam, AC6),
//     then DoneEvent(toolUse).
//   * any other turn (including the turn after a tool result) → report the
//     executed tool, DoneEvent(stop).
// `selfTest()` asserts the tool result lands in the transcript.
import 'dart:convert';

import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/types.dart';

// ---------------------------------------------------------------------------
// fake: provider — deterministic, no network. Script (test seam, AC2/AC3):
//   * user prompt containing "navigate <url>" → echo text + one
//     `browser_navigate` tool call, then DoneEvent(toolUse).
//   * a steering mail shaped "[from <sender>] dm <text>" → one `dap_dm`
//     tool call replying to the sender (deterministic E2E DM seam, AC6),
//     then DoneEvent(toolUse).
//   * any other turn (including the turn after a tool result) → report the
//     executed tool, DoneEvent(stop).
// `selfTest()` asserts the tool result lands in the transcript.
// ---------------------------------------------------------------------------

AssistantMessageEventStream fakeStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  final last = context.messages.isEmpty ? null : context.messages.last;

  // A turn that answers a tool result: report the outcome, stop.
  if (last is ToolResultMessage) {
    final ok = !last.isError;
    _emitText(
      stream,
      model,
      'fake: ${last.toolName} ${ok ? 'succeeded' : 'failed'}',
      StopReason.stop,
    );
    return stream;
  }

  // A fresh user turn.
  final prompt = last is UserMessage && last.content is String
      ? last.content as String
      : '';

  // Steering DM: "[from <sender>] dm <text>" → dap_dm back to the sender.
  final dm = RegExp(
    r'^\[from (\S+)\] dm (.*)',
    dotAll: true,
  ).firstMatch(prompt);
  if (dm != null) {
    _emitDm(stream, model, to: dm.group(1)!, text: 'fake: dm ${dm.group(2)!}');
    return stream;
  }

  final navigateIndex = prompt.toLowerCase().indexOf('navigate');
  if (navigateIndex >= 0) {
    final rest = prompt.substring(navigateIndex + 'navigate'.length).trim();
    final url = rest.isEmpty
        ? 'data:text/html,<h1>fa-fake</h1>'
        : rest.split(RegExp(r'\s')).first;
    _emitNavigate(stream, model, url);
    return stream;
  }
  _emitText(
    stream,
    model,
    prompt.isEmpty ? 'fake: (empty prompt)' : 'fake: $prompt',
    StopReason.stop,
  );
  return stream;
}

void _emitNavigate(
  AssistantMessageEventStream stream,
  Model model,
  String url,
) {
  _emitToolCall(
    stream,
    model,
    'fake: navigating to $url',
    ToolCall(
      id: 'fake-call-1',
      name: 'browser_navigate',
      arguments: {'url': url},
    ),
  );
}

void _emitDm(
  AssistantMessageEventStream stream,
  Model model, {
  required String to,
  required String text,
}) {
  _emitToolCall(
    stream,
    model,
    'fake: dm → $to',
    ToolCall(
      id: 'fake-call-dm',
      name: 'dap_dm',
      arguments: {'to': to, 'text': text},
    ),
  );
}

/// Streams [text] then [call], ending with DoneEvent(toolUse) — the one
/// scripted tool-call shape every fake turn shares.
void _emitToolCall(
  AssistantMessageEventStream stream,
  Model model,
  String text,
  ToolCall call,
) {
  AssistantMessage partial(
    List<ContentBlock> content, [
    StopReason reason = StopReason.stop,
  ]) => AssistantMessage(
    content: content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: reason,
    timestamp: DateTime.now(),
  );

  final textOnly = [TextContent(text: text)];
  stream.push(StartEvent(partial: partial(textOnly)));
  stream.push(TextStartEvent(contentIndex: 0, partial: partial(textOnly)));
  stream.push(
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial(textOnly)),
  );
  stream.push(
    TextEndEvent(contentIndex: 0, content: text, partial: partial(textOnly)),
  );

  final withCall = <ContentBlock>[TextContent(text: text), call];
  stream.push(ToolCallStartEvent(contentIndex: 1, partial: partial(withCall)));
  stream.push(
    ToolCallDeltaEvent(
      contentIndex: 1,
      delta: jsonEncode(call.arguments),
      partial: partial(withCall),
    ),
  );
  stream.push(
    ToolCallEndEvent(
      contentIndex: 1,
      toolCall: call,
      partial: partial(withCall),
    ),
  );
  stream.push(
    DoneEvent(reason: StopReason.toolUse, message: partial(withCall)),
  );
  stream.end();
}

void _emitText(
  AssistantMessageEventStream stream,
  Model model,
  String text,
  StopReason done,
) {
  AssistantMessage partial() => AssistantMessage(
    content: [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: done,
    timestamp: DateTime.now(),
  );

  stream.push(StartEvent(partial: partial()));
  stream.push(TextStartEvent(contentIndex: 0, partial: partial()));
  stream.push(TextDeltaEvent(contentIndex: 0, delta: text, partial: partial()));
  stream.push(TextEndEvent(contentIndex: 0, content: text, partial: partial()));
  stream.push(DoneEvent(reason: done, message: partial()));
  stream.end();
}
