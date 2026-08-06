import 'package:fa_llm/fa_llm.dart';
import 'package:fa_llm_flutter/fa_llm_flutter.dart';
import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model_response.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockInferenceChat extends Mock implements gemma.InferenceChat {}

class _FakeMessage extends Fake implements Message {}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeMessage());
  });

  group(FlutterGemmaProvider, () {
    late _MockInferenceChat chat;
    late FlutterGemmaProvider provider;

    setUp(() {
      chat = _MockInferenceChat();
      provider = FlutterGemmaProvider(defaultModel: 'gemma-test', chat: chat);
    });

    test('defaultModel is exposed', () {
      expect(provider.defaultModel, 'gemma-test');
    });

    test('chat sends a user message and returns response text', () async {
      when(() => chat.addQuery(any())).thenAnswer((_) async {});
      when(
        () => chat.generateChatResponse(),
      ).thenAnswer((_) async => const TextResponse('Hello!'));

      final response = await provider.chat('Hi');

      expect(response, 'Hello!');
      verify(
        () =>
            chat.addQuery(any(that: _isMessageWith(text: 'Hi', isUser: true))),
      ).called(1);
    });

    test('chatMessages builds a single prompt from messages', () async {
      when(() => chat.addQuery(any())).thenAnswer((_) async {});
      when(
        () => chat.generateChatResponse(),
      ).thenAnswer((_) async => const TextResponse('OK'));

      final response = await provider.chatMessages([
        const LlmMessage(role: 'system', content: 'Be brief.'),
        const LlmMessage(role: 'user', content: 'Hello'),
        const LlmMessage(role: 'assistant', content: 'Hi there.'),
      ]);

      expect(response, 'OK');
      verify(
        () => chat.addQuery(
          any(
            that: _isMessageWith(
              text: 'System: Be brief.\nUser: Hello\nAssistant: Hi there.',
              isUser: true,
            ),
          ),
        ),
      ).called(1);
    });

    test('chatStream yields tokens from the async generator', () async {
      when(() => chat.addQuery(any())).thenAnswer((_) async {});
      when(() => chat.generateChatResponseAsync()).thenAnswer(
        (_) => Stream.fromIterable([
          const TextResponse('Hello'),
          const TextResponse(' world'),
        ]),
      );

      final tokens = await provider.chatStream('Hi').toList();

      expect(tokens, ['Hello', ' world']);
    });

    test('ignores non-text responses in the stream', () async {
      when(() => chat.addQuery(any())).thenAnswer((_) async {});
      when(() => chat.generateChatResponseAsync()).thenAnswer(
        (_) => Stream.fromIterable([
          const TextResponse('A'),
          const ThinkingResponse('thinking...'),
          const TextResponse('B'),
        ]),
      );

      final tokens = await provider.chatStream('Hi').toList();

      expect(tokens, ['A', 'B']);
    });
  });
}

Matcher _isMessageWith({required String text, required bool isUser}) {
  return isA<Message>()
      .having((m) => m.text, 'text', text)
      .having((m) => m.isUser, 'isUser', isUser);
}
