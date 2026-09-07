// Pure AgentEvent → panel event mappings for the extension agent host.
//
// agent_host.dart is web-only (package:web arrives via fetch_client), so
// these pure translations live here where VM tests can pin them (see
// test/host_events_test.dart). Contract: every returned map is JSON-able
// and rides the panel relay verbatim (StreamMsg), except message_done /
// approval_request which the port server wraps into dedicated envelopes.

import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'browser_api_tools.dart' show screenshotToolResult;

/// One AgentEvent → panel event map, or null for events the panel does
/// not consume. Thinking deltas map to `thinking_delta` — they used to be
/// dropped silently and the panel never saw any reasoning.
Map<String, dynamic>? hostEventOf(AgentEvent event) {
  switch (event) {
    case MessageUpdateEvent(:final assistantMessageEvent):
      switch (assistantMessageEvent) {
        case TextDeltaEvent(:final delta):
          return {'type': 'delta', 'text': delta};
        case ThinkingDeltaEvent(:final delta):
          return {'type': 'thinking_delta', 'text': delta};
        default:
          return null;
      }
    case MessageEndEvent(:final message):
      return {'type': 'message_done', ...messageToJs(message)};
    case ToolExecutionEndEvent(
      :final toolCallId,
      :final toolName,
      :final result,
      :final isError,
    ):
      return {
        'type': 'tool_result',
        'toolCallId': toolCallId,
        'toolName': toolName,
        'isError': isError,
        // Text only: image blocks stay out of the UI (and out of the
        // replay ring) — a screenshot's base64 would flood both.
        'text': result.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n'),
      };
    default:
      return null;
  }
}

/// A finalized message → the compact UI shape (`text`, `toolCalls`,
/// `toolName`, `isError`, `error`). Image blocks are intentionally not
/// rendered — the panel shows what was said, not pixel payloads.
Map<String, dynamic> messageToJs(Message message) {
  final text = switch (message) {
    AssistantMessage(:final content) => [
      for (final block in content)
        if (block is TextContent) block.text,
    ].join('\n'),
    UserMessage(:final content) when content is String => content,
    ToolResultMessage(:final content) => [
      for (final block in content)
        if (block is TextContent) block.text,
    ].join('\n'),
    _ => '',
  };
  return {
    'role': message.role,
    'text': text,
    // Tool-call names let the UI tell a tool-call-only turn (no text,
    // the tool results tell the story) apart from a genuinely empty
    // response (placeholder-worthy).
    if (message is AssistantMessage)
      'toolCalls': [
        for (final block in message.content)
          if (block is ToolCall) block.name,
      ],
    if (message is ToolResultMessage) 'toolName': message.toolName,
    if (message is ToolResultMessage) 'isError': message.isError,
    if (message is AssistantMessage && message.errorMessage != null)
      'error': message.errorMessage,
  };
}

/// The v1 `browser_*` op bridge: unwraps the `{ok, result}` envelope an op
/// resolves with. A screenshot result's `pngBase64` becomes a vision
/// [ImageContent] block — the model SEES the shot (the fake provider even
/// acknowledges it; see the fake provider's image-seen reply) — while the
/// text channel keeps only the compact metadata. Everything else stays
/// compact JSON text, `ok` when the op produced nothing.
ToolExecutionResult v1OpToolResult(String op, Map<String, dynamic> envelope) {
  final result = envelope['result'];
  if (result is Map && op == 'screenshot') {
    final png = result['pngBase64'];
    if (png is String && png.isNotEmpty) {
      final meta = <String, Object?>{
        for (final MapEntry(:key, :value) in result.entries)
          if (key != 'pngBase64') key: value as Object?,
      };
      return screenshotToolResult(png, meta: meta);
    }
  }
  return ToolExecutionResult.text(result == null ? 'ok' : jsonEncode(result));
}
