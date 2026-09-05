// Provider stream construction for the extension agent: an OpenAI-like
// streaming function over the core `streamOpenAICompletions` adapter (pure
// and web-safe), plus the deterministic `fake:` provider used by CI (AC2).
//
// The core sse_decoder is reused INSIDE the core adapter — nothing here
// parses SSE by hand; the only web-specific piece is the fetch-backed
// http.Client (see fetch_client.dart) installed once at boot.
import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show StreamFunction;
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/openai_completions.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;
import 'package:flutter_agent_harness/src/types.dart';

import 'fetch_client.dart';

/// Resolved provider settings (from chrome.storage `faProvider`).
typedef ProviderConfig = ({String baseUrl, String apiKey, String model});

/// Model ids starting with `fake:` select the deterministic CI provider.
bool isFakeModel(String model) => model.startsWith('fake:');

/// Builds the [Model] spec sent with every request (and persisted in
/// `model_change` session records).
Model modelForConfig(ProviderConfig config) => Model(
  id: config.model,
  name: config.model,
  api: 'openai-completions',
  provider: isFakeModel(config.model) ? 'fake' : 'openai-like',
  baseUrl: config.baseUrl,
  contextWindow: 128000,
  maxTokens: 8192,
);

/// Streams via the core openai-completions adapter using the platform
/// `fetch` (MV3 service workers have no XHR for package:http's default
/// client). The api key rides [OpenAICompletionsOptions] and never leaves
/// the service worker (AC8).
StreamFunction openAiLikeStream(ProviderConfig config) {
  providerHttpClientFactory = () => FetchClient();
  return (model, context, {cancelToken}) => streamOpenAICompletions(
    model,
    context,
    OpenAICompletionsOptions(
      apiKey: config.apiKey.isEmpty ? null : config.apiKey,
      cancelToken: cancelToken,
    ),
  );
}

/// Resolves the stream function for [config]: `fake:*` → scripted
/// deterministic provider; anything else → the openai-like adapter.
StreamFunction resolveStreamFn(ProviderConfig config) {
  providerHttpClientFactory = () => FetchClient();
  return isFakeModel(config.model) ? fakeStream : openAiLikeStream(config);
}

// ---------------------------------------------------------------------------
// fake: provider — deterministic, no network. Script (test seam, AC2/AC3):
//   * user prompt containing "navigate <url>" → echo text + one
//     `browser_navigate` tool call, then DoneEvent(toolUse).
//   * any other turn (including the turn after a tool result) → echo text,
//     DoneEvent(stop).
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
      'fake: browser_navigate ${ok ? 'succeeded' : 'failed'}',
      StopReason.stop,
    );
    return stream;
  }

  // A fresh user turn.
  final prompt = last is UserMessage && last.content is String
      ? last.content as String
      : '';
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
  final text = 'fake: navigating to $url';
  final call = ToolCall(
    id: 'fake-call-1',
    name: 'browser_navigate',
    arguments: {'url': url},
  );

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
      delta: '{"url": "$url"}',
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
