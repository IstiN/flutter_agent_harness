# fa_llm

Reusable LLM provider adapters for Fa and related projects.

Pure Dart core: OpenAI-compatible, OpenRouter, Ollama, and configuration.

## Usage

```dart
import 'package:fa_llm/fa_llm.dart';

final provider = ProviderFactory.create(
  LlmConfig(
    providerName: 'openai',
    apiKey: 'sk-...',
    baseUrl: 'https://api.openai.com/v1/chat/completions',
    model: 'gpt-4o',
  ),
);
```

## Configuration

`LlmConfig.fromEnvironment()` resolves each value in order: the explicit
argument, then the `{PROVIDER}_…` environment variable, then the same name in
a project-root `.env` file, then the built-in default. `PROVIDER` is `OPENAI`
(the default), `OPENROUTER`, or `OLLAMA`.

| Variable | Value |
| --- | --- |
| `{PROVIDER}_API_KEY` | API key |
| `{PROVIDER}_MODEL` | Model id |
| `{PROVIDER}_BASE_PATH` | Base URL — wins over `{PROVIDER}_BASE_URL` when both are set |
| `{PROVIDER}_BASE_URL` | Base URL (see below) |

A base URL may be an origin (`http://127.0.0.1:8931`), a versioned base
(`http://127.0.0.1:8931/v1`), or the full endpoint
(`https://api.openai.com/v1/chat/completions`); it is normalized to the full
chat-completions endpoint the providers POST to, so a local proxy (recorder,
gateway, cost tracker) can be pointed at with its origin alone.

## Features

- OpenAI-compatible streaming completions
- OpenRouter model routing
- Ollama local inference
- Provider configuration and resolution
- Token counting and context window management
