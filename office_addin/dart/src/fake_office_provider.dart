// The deterministic scripted provider for the Office taskpane (issue #89):
// the Office twin of the extension's fake_provider.dart — a StreamFunction
// with NO network and NO web-only imports, so it is dart2js-compileable and
// VM-testable. The host streams with it until a real provider is
// configured (fake:not-configured).
//
// Script (test seam):
//   * user text containing "read item" → one outlook.read_current_item
//     tool call, then DoneEvent(toolUse).
//   * "attach <name>" → one outlook.read_attachment {name} call.
//   * "insert … into: <text>" → one outlook.insert_draft_body {text} call.
//   * after a tool result → plain reply ('Item read.' / 'Draft updated.' /
//     'Attachment read.' / generic), DoneEvent(stop).
//   * any other turn → generic ack, DoneEvent(stop).
//
// AC6 (IT-injection): directives are matched ONLY in the user-typed
// portion of the turn. Every `<email-body …>…</email-body>` span in the
// turn text (a quoted email pasted into chat, or a context injector that
// carries a quarantined body) is masked out before scanning — an email
// body saying "read item" or "insert into: pwned" can never trigger a
// tool branch.
import 'dart:convert';

import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'outlook_tools.dart'
    show outlookInsertDraftBody, outlookReadAttachment, outlookReadCurrentItem;

// ponytail: quarantine fence literals — email_quarantine.dart keeps them
// private; mirror them here so masking never drifts from that file's shape.
const _fenceOpen = '<email-body';
const _fenceClose = '</email-body>';

/// Streams the scripted turn for [context].
AssistantMessageEventStream officeFakeStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final stream = AssistantMessageEventStream();
  final last = context.messages.isEmpty ? null : context.messages.last;

  // A turn that answers a tool result: report the outcome, stop.
  if (last is ToolResultMessage) {
    final ok = !last.isError;
    final text = switch (last.toolName) {
      outlookReadCurrentItem when ok => 'Item read.',
      outlookInsertDraftBody when ok => 'Draft updated.',
      outlookReadAttachment when ok => 'Attachment read.',
      _ => 'fake: ${last.toolName} ${ok ? 'succeeded' : 'failed'}',
    };
    _emitText(stream, model, text, StopReason.stop);
    return stream;
  }

  // A fresh user turn. Scan ONLY the directive portion: quarantine fences
  // in the turn text are masked before matching (AC6).
  final prompt = last is UserMessage && last.content is String
      ? last.content as String
      : '';
  final directive = _scanDirective(_maskQuarantined(prompt), prompt);
  if (directive != null) {
    final (text, call) = directive;
    _emitToolCall(stream, model, text, call);
    return stream;
  }
  _emitText(stream, model, 'fake: ack', StopReason.stop);
  return stream;
}

/// One scripted tool turn: the streamed text and the tool call.
typedef _Directive = (String, ToolCall);

/// Finds the first directive OUTSIDE quarantine fences. [masked] is the
/// same length as [prompt] with every fence span blanked, so match
/// indices slice [prompt] directly.
_Directive? _scanDirective(String masked, String prompt) {
  final read = RegExp('read item', caseSensitive: false).firstMatch(masked);
  if (read != null) {
    return (
      'fake: reading the open item',
      ToolCall(
        id: 'fake-call-read',
        name: outlookReadCurrentItem,
        arguments: <String, dynamic>{},
      ),
    );
  }
  final attach = RegExp(
    r'attach\s+\S',
    caseSensitive: false,
  ).firstMatch(masked);
  if (attach != null) {
    final name = masked.substring(attach.start).split('\n').first;
    final nameArg = name
        .replaceFirst(RegExp(r'^attach\s+', caseSensitive: false), '')
        .trim();
    if (nameArg.isNotEmpty) {
      return (
        'fake: reading attachment $nameArg',
        ToolCall(
          id: 'fake-call-attach',
          name: outlookReadAttachment,
          arguments: {'name': nameArg},
        ),
      );
    }
  }
  final insert = RegExp(r'\binsert\b', caseSensitive: false).firstMatch(masked);
  if (insert != null) {
    final into = RegExp(
      r'\binto\b\s*:? ?',
      caseSensitive: false,
    ).firstMatch(masked.substring(insert.end));
    final rest = prompt.substring(insert.end);
    final text = (into == null ? rest : rest.substring(into.end)).trim();
    if (text.isNotEmpty) {
      return (
        'fake: updating the draft',
        ToolCall(
          id: 'fake-call-insert',
          name: outlookInsertDraftBody,
          arguments: {'text': text},
        ),
      );
    }
  }
  return null;
}

/// Blanks every `<email-body …>…</email-body>` span (unterminated fences
/// mask to the end) with spaces — same length as the input, so match
/// indices stay valid against the original text.
String _maskQuarantined(String text) {
  if (!text.contains(_fenceOpen)) return text;
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final open = text.indexOf(_fenceOpen, i);
    if (open < 0) {
      out.write(text.substring(i));
      break;
    }
    out.write(text.substring(i, open));
    final close = text.indexOf(_fenceClose, open);
    final end = close < 0 ? text.length : close + _fenceClose.length;
    out.write(' ' * (end - open));
    i = end;
  }
  return out.toString();
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

/// Streams a plain assistant text turn ending with [done].
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
