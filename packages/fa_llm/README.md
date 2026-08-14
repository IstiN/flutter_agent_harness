# fa_llm

Reusable LLM provider adapters for Fa and related projects.

Pure Dart core: OpenAI-compatible, OpenRouter, Ollama, and configuration.

## Usage

```dart
import 'package:fa_llm/fa_llm.dart';

final provider = openaiProvider(
  baseUrl: 'https://api.openai.com/v1',
  apiKey: 'sk-...',
  model: 'gpt-4o',
);
```

## Features

- OpenAI-compatible streaming completions
- OpenRouter model routing
- Ollama local inference
- Provider configuration and resolution
- Token counting and context window management