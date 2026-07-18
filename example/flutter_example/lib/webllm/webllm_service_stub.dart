// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host (non-web) stub for the WebLLM engine: on-device inference needs the
/// browser-only `@mlc-ai/web-llm` runtime, so every operation reports
/// unavailability instead of failing obscurely.
library;

import 'webllm_types.dart';

/// The message shown when the on-device provider is used off the web.
const webLlmUnavailableMessage =
    'On-device inference (WebLLM) is only available in the web build of '
    'this app. Pick a hosted provider here, or open the web demo in '
    'Chrome/Edge.';

/// Returns a stub [WebLlmEngineApi] that reports unavailable.
WebLlmEngineApi createWebLlmService() => WebLlmService();

/// A [WebLlmEngineApi] that reports on-device inference as unavailable.
final class WebLlmService implements WebLlmEngineApi {
  @override
  bool get isAvailable => false;

  @override
  String? get loadedModelId => null;

  @override
  Stream<WebLlmProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(WebLlmModelPreset preset) =>
      Future.error(StateError(webLlmUnavailableMessage));

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
  }) => Future.error(StateError(webLlmUnavailableMessage));

  @override
  Future<void> interrupt() async {}
}
