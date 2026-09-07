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
//   * "inject_js <tabId> <world> <code…>" → one `inject_js` tool call with
//     the tab/world/code verbatim (bad worlds fail cleanly in the tool, E2).
//   * "sessions_restore <sessionId>" → one `sessions_restore` tool call.
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
//   * "inject_js <tabId> <world> <code…>" → one `inject_js` tool call with
//     the tab/world/code verbatim (bad worlds fail cleanly in the tool, E2).
//   * "sessions_restore <sessionId>" → one `sessions_restore` tool call.
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

  // A turn that answers a tool result: report the outcome, stop. A tool
  // result carrying a vision image block is acknowledged — the scripted
  // stand-in for what a vision model would do with a screenshot.
  if (last is ToolResultMessage) {
    final ok = !last.isError;
    final seesImage = last.content.any((block) => block is ImageContent);
    _emitText(
      stream,
      model,
      'fake: ${last.toolName} ${ok ? 'succeeded' : 'failed'}'
      '${seesImage ? ' (image seen)' : ''}',
      StopReason.stop,
    );
    return stream;
  }

  // A fresh user turn.
  final prompt = last is UserMessage && last.content is String
      ? last.content as String
      : '';

  // Steering DM: "[from <sender>] dm <text>" → dap_dm back to the sender.
  // NOT ^-anchored: the host prepends a "[context] active tab: …" line to
  // turns (issue #34), and an anchored match then never fires — the DM was
  // echoed instead of answered (issue #41).
  final dm = RegExp(r'\[from (\S+)\] dm (.*)', dotAll: true).firstMatch(prompt);
  if (dm != null) {
    _emitDm(stream, model, to: dm.group(1)!, text: 'fake: dm ${dm.group(2)!}');
    return stream;
  }

  // Page-code injection: "inject_js <tabId> <world> <code…>" — code is the
  // rest of the match, verbatim. A bad world is emitted as-is: the tool's
  // clean `bad_world` result (E2) is the observable under test. NOT
  // ^-anchored: the host prepends a "[context] active tab: …" line to
  // turns (issue #34) — an anchored match never fires (same trap the dm
  // directive hit in issue #41).
  final inject = RegExp(
    r'inject_js (\d+) (\S+) (.+)',
    dotAll: true,
  ).firstMatch(prompt);
  if (inject != null) {
    _emitInjectJs(
      stream,
      model,
      tabId: int.parse(inject.group(1)!),
      world: inject.group(2)!,
      code: inject.group(3)!,
    );
    return stream;
  }

  // Session restore: "sessions_restore <sessionId>" (the tool requires the
  // id from sessions_recent — there is no default restore path). Unanchored
  // for the same [context]-prefix reason as inject_js.
  final restore = RegExp(r'sessions_restore (\S+)').firstMatch(prompt);
  if (restore != null) {
    _emitSessionsRestore(stream, model, sessionId: restore.group(1)!);
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

  // "screenshot" anywhere in the prompt → the v1 screenshot op.
  if (prompt.toLowerCase().contains('screenshot')) {
    _emitToolCall(
      stream,
      model,
      'fake: capturing the page',
      ToolCall(id: 'fake-call-shot', name: 'browser_screenshot', arguments: {}),
    );
    return stream;
  }

  // "think" streams a reasoning block before the text — exercises the
  // panel's thinking_delta path (CI seam for the reasoning UI).
  if (prompt.toLowerCase().contains('think')) {
    _emitThinking(
      stream,
      model,
      'fake: weighing the request…',
      'fake: done thinking',
    );
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

void _emitInjectJs(
  AssistantMessageEventStream stream,
  Model model, {
  required int tabId,
  required String world,
  required String code,
}) {
  _emitToolCall(
    stream,
    model,
    'fake: inject_js $world → tab $tabId',
    ToolCall(
      id: 'fake-call-inject',
      name: 'inject_js',
      arguments: {'tabId': tabId, 'world': world, 'code': code},
    ),
  );
}

void _emitSessionsRestore(
  AssistantMessageEventStream stream,
  Model model, {
  required String sessionId,
}) {
  _emitToolCall(
    stream,
    model,
    'fake: sessions_restore $sessionId',
    ToolCall(
      id: 'fake-call-restore',
      name: 'sessions_restore',
      arguments: {'sessionId': sessionId},
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

/// Streams a thinking block (Start/Delta/End at index 0) followed by the
/// text block (index 1) — the reasoning shape real providers produce.
void _emitThinking(
  AssistantMessageEventStream stream,
  Model model,
  String thinking,
  String text,
) {
  AssistantMessage partial(List<ContentBlock> content) => AssistantMessage(
    content: content,
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );

  final thinkingOnly = [ThinkingContent(thinking: thinking)];
  stream.push(StartEvent(partial: partial(thinkingOnly)));
  stream.push(
    ThinkingStartEvent(contentIndex: 0, partial: partial(thinkingOnly)),
  );
  stream.push(
    ThinkingDeltaEvent(
      contentIndex: 0,
      delta: thinking,
      partial: partial(thinkingOnly),
    ),
  );
  stream.push(
    ThinkingEndEvent(
      contentIndex: 0,
      content: thinking,
      partial: partial(thinkingOnly),
    ),
  );

  final withText = [
    ThinkingContent(thinking: thinking),
    TextContent(text: text),
  ];
  stream.push(TextStartEvent(contentIndex: 1, partial: partial(withText)));
  stream.push(
    TextDeltaEvent(contentIndex: 1, delta: text, partial: partial(withText)),
  );
  stream.push(
    TextEndEvent(contentIndex: 1, content: text, partial: partial(withText)),
  );
  stream.push(DoneEvent(reason: StopReason.stop, message: partial(withText)));
  stream.end();
}
