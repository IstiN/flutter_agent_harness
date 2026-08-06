import 'dart:async';

import 'package:fa_llm/fa_llm.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;

/// An [LlmProvider] implementation backed by the `flutter_gemma` plugin.
///
/// The plugin manages its own model session, so callers typically inject a
/// pre-configured [gemma.InferenceChat] (created from a loaded model) rather
/// than constructing the provider from raw configuration.
///
/// Example:
/// ```dart
/// final inferenceChat = await FlutterGemma().createChat(...);
/// final provider = FlutterGemmaProvider(
///   defaultModel: 'gemma4-31b',
///   chat: inferenceChat,
/// );
/// final response = await provider.chat('Hello!');
/// ```
class FlutterGemmaProvider extends LlmProvider {
  /// Creates a provider wrapping the given [gemma.InferenceChat].
  FlutterGemmaProvider({required this.defaultModel, required this._chat});

  final gemma.InferenceChat _chat;

  @override
  final String defaultModel;

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) async {
    await _chat.addQuery(gemma.Message.text(text: prompt, isUser: true));
    final response = await _chat.generateChatResponse();
    return _extractText(response);
  }

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async {
    final prompt = _messagesToPrompt(messages);
    return chat(prompt, model: model, onCancel: onCancel);
  }

  @override
  Stream<String> chatStream(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) async* {
    await _chat.addQuery(gemma.Message.text(text: prompt, isUser: true));
    await for (final response in _chat.generateChatResponseAsync()) {
      final text = _extractText(response);
      if (text.isNotEmpty) {
        yield text;
      }
    }
  }

  @override
  Stream<String> chatMessagesStream(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async* {
    final prompt = _messagesToPrompt(messages);
    yield* chatStream(prompt, model: model, onCancel: onCancel);
  }

  String _messagesToPrompt(List<LlmMessage> messages) {
    final buffer = StringBuffer();
    for (final message in messages) {
      final role = _displayRole(message.role);
      buffer.writeln('$role: ${message.content}');
    }
    return buffer.toString().trim();
  }

  String _displayRole(String role) {
    switch (role) {
      case 'system':
        return 'System';
      case 'user':
        return 'User';
      case 'assistant':
        return 'Assistant';
      default:
        return role.substring(0, 1).toUpperCase() + role.substring(1);
    }
  }

  String _extractText(gemma.ModelResponse response) {
    if (response is gemma.TextResponse) {
      return response.token;
    }
    return '';
  }
}
