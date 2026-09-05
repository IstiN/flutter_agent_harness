// Provider stream construction for the extension agent: an OpenAI-like
// streaming function over the core `streamOpenAICompletions` adapter (pure
// and web-safe) plus resolution for the deterministic `fake:` provider
// (fake_provider.dart — pure Dart, VM-testable; re-exported here so the
// agent host keeps a single import).
//
// The core sse_decoder is reused INSIDE the core adapter — nothing here
// parses SSE by hand; the only web-specific piece is the fetch-backed
// http.Client (see fetch_client.dart) installed once at boot.
import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show StreamFunction;
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/openai_completions.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;

import 'fake_provider.dart' show fakeStream;
import 'fetch_client.dart';

export 'fake_provider.dart' show fakeStream;

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
