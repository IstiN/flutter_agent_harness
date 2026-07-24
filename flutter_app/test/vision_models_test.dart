import 'package:fa/agent_service.dart';
import 'package:fa/vision_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('modelIdSuggestsVision', () {
    test('mainstream vision models are detected', () {
      const visionIds = [
        'gpt-4o-mini',
        'openai/gpt-4o',
        'gpt-4.1-nano',
        'gpt-5',
        'anthropic/claude-sonnet-4',
        'claude-3.5-haiku',
        'google/gemini-2.0-flash-001',
        'gemini-2.5-pro',
        'qwen/qwen2.5-vl-72b-instruct',
        'qwen2-vl-7b',
        'mistralai/pixtral-12b',
        'mistral-small-3.1-24b-instruct',
        'ministral-8b',
        'meta-llama/llama-3.2-11b-vision-instruct',
        'llama-4-scout',
        'llava-1.5-7b',
        'moondream2',
        'glm-4v-9b',
        'zai/glm-4.5v',
        'x-ai/grok-4',
        'grok-2-vision-1212',
        'google/gemma-3-27b-it',
        'phi-4-multimodal-instruct',
        'internvl2-8b',
        'some-host/my-vision-model',
      ];
      for (final id in visionIds) {
        expect(modelIdSuggestsVision(id), isTrue, reason: id);
      }
    });

    test('text-only models are not flagged', () {
      const textIds = [
        '',
        'gpt-3.5-turbo',
        'deepseek-chat',
        'deepseek-v3',
        'qwen2.5-coder-32b-instruct',
        'qwq-32b',
        'google/gemma-3-1b-it',
        'text-embedding-3-large',
        'llama-3.1-8b-instruct',
        'mistral-7b-instruct',
        'gpt-oss:120b',
      ];
      for (final id in textIds) {
        expect(modelIdSuggestsVision(id), isFalse, reason: id);
      }
    });
  });

  group('AgentConfig.toModel input', () {
    test('defaults to the vision heuristic from the model id', () {
      final config = AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'openai/gpt-4o-mini',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'k',
      );
      expect(config.toModel().input, contains('image'));
    });

    test('unknown ids stay text-only by default', () {
      final config = AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'my-local-model',
        baseUrl: 'http://localhost:1234/v1',
        apiKey: '',
      );
      expect(config.toModel().input, isNot(contains('image')));
    });

    test('an explicit flag wins over the heuristic', () {
      final blind = AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'gpt-4o',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'k',
        supportsImages: false,
      );
      expect(blind.toModel().input, isNot(contains('image')));
      final sighted = AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'my-local-model',
        baseUrl: 'http://localhost:1234/v1',
        apiKey: '',
        supportsImages: true,
      );
      expect(sighted.toModel().input, contains('image'));
    });
  });
}
