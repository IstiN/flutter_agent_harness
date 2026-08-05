// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_llm/fa_llm.dart' as fa_llm;

import 'connection.dart';
import 'provider_preset.dart';

/// Maps a [FaChatModelConfig] to the canonical [fa_llm.LlmConfig] so the
/// host can build an [fa_llm.LlmProvider] from the same settings the UI
/// collected.
///
/// On-device provider kinds (`webllm`, `gemma`, `transformers_js`) have no
/// hosted endpoint, so this mapping is meaningful only for the
/// OpenAI-compatible presets and custom providers.
extension FaChatModelConfigLlmMapping on FaChatModelConfig {
  fa_llm.LlmConfig toLlmConfig() {
    return fa_llm.LlmConfig(
      providerName: _providerNameFor(providerKind),
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: modelId,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
    );
  }
}

/// Maps a hosted [ProviderPreset] to a default [fa_llm.LlmConfig].
///
/// The API key is left empty because presets resolve their keys through
/// the host's key resolver / [SessionKeysStore], not the preset itself.
extension ProviderPresetLlmMapping on ProviderPreset {
  fa_llm.LlmConfig? toDefaultLlmConfig() {
    final url = baseUrl;
    if (url == null) return null;
    return fa_llm.LlmConfig(
      providerName: _providerNameFor(name),
      apiKey: '',
      baseUrl: url,
      model: defaultModel,
    );
  }
}

String _providerNameFor(String providerKind) {
  return switch (providerKind.toLowerCase()) {
    'openrouter' => 'openrouter',
    'ollama' || 'ollama-cloud' => 'ollama',
    'openai' || 'openai-completions' => 'openai',
    _ => 'openai',
  };
}
