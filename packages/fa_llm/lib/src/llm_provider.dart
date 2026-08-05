import 'dart:async';

import 'llm_message.dart';

/// Abstract interface for any LLM provider.
///
/// Implementations can be swapped in at runtime, making the whole system
/// provider-agnostic.
abstract class LlmProvider {
  String get defaultModel;

  /// Send a single user prompt and return the generated text.
  ///
  /// [onCancel] is invoked by the provider if the call times out or is
  /// interrupted, giving the caller a chance to call provider-specific cancel
  /// logic (e.g. WebLLM interruptGenerate).
  Future<String> chat(String prompt, {String? model, void Function()? onCancel});

  /// Send a conversation and return the generated text.
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  });

  /// Streams generated tokens in real-time.
  ///
  /// The default implementation waits for [chat] and emits the full response
  /// as a single event. Providers that support true streaming should override
  /// this to emit partial output as it becomes available.
  Stream<String> chatStream(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) async* {
    yield await chat(prompt, model: model, onCancel: onCancel);
  }

  /// Streams a conversation in real-time.
  Stream<String> chatMessagesStream(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async* {
    yield await chatMessages(messages, model: model, onCancel: onCancel);
  }

  /// Cancels an in-flight generation, if supported.
  ///
  /// The default does nothing. Override in providers that expose interrupt
  /// semantics (e.g. WebLLM).
  Future<void> cancel() async {}
}
