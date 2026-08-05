// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaChatModelConfigLlmMapping', () {
    test('maps OpenRouter preset config to openrouter provider', () {
      const config = FaChatModelConfig(
        providerKind: 'openrouter',
        modelId: 'openai/gpt-4o',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'sk-or',
        contextWindow: 128000,
        maxTokens: 4096,
      );
      final llmConfig = config.toLlmConfig();
      expect(llmConfig.providerName, 'openrouter');
      expect(llmConfig.model, 'openai/gpt-4o');
      expect(llmConfig.baseUrl, 'https://openrouter.ai/api/v1');
      expect(llmConfig.apiKey, 'sk-or');
      expect(llmConfig.contextWindow, 128000);
      expect(llmConfig.maxTokens, 4096);
    });

    test('maps custom provider config to openai provider by default', () {
      const config = FaChatModelConfig(
        providerKind: 'openai-completions',
        modelId: 'gpt-4o-mini',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
      );
      final llmConfig = config.toLlmConfig();
      expect(llmConfig.providerName, 'openai');
      expect(llmConfig.model, 'gpt-4o-mini');
      expect(llmConfig.apiKey, 'sk-test');
    });

    test('maps Ollama Cloud preset to ollama provider', () {
      const config = FaChatModelConfig(
        providerKind: 'ollama',
        modelId: 'gemma4:31b',
        baseUrl: 'https://ollama.com/v1',
        apiKey: '',
      );
      final llmConfig = config.toLlmConfig();
      expect(llmConfig.providerName, 'ollama');
      expect(llmConfig.model, 'gemma4:31b');
    });
  });

  group('ProviderPresetLlmMapping', () {
    test('OpenRouter preset has default config', () {
      final config = ProviderPreset.openrouter.toDefaultLlmConfig();
      expect(config, isNotNull);
      expect(config!.providerName, 'openrouter');
      expect(config.model, ProviderPreset.openrouter.defaultModel);
      expect(config.baseUrl, ProviderPreset.openrouter.baseUrl);
    });

    test('on-device presets have no default hosted config', () {
      expect(ProviderPreset.gemma.toDefaultLlmConfig(), isNull);
      expect(ProviderPreset.webllm.toDefaultLlmConfig(), isNull);
      expect(ProviderPreset.transformersJs.toDefaultLlmConfig(), isNull);
    });
  });
}
