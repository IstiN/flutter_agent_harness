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
| `{PROVIDER}_MAX_TOKENS` | Max output tokens (`int`, optional) |
| `{PROVIDER}_CONTEXT_WINDOW` | Context window (`int`, optional) |
| `{PROVIDER}_TEMPERATURE` | Sampling temperature (`double`, optional) |
| `{PROVIDER}_MAX_TOKENS_PARAM_NAME` | `max_tokens` payload key (default `max_completion_tokens`) |

An origin (`http://127.0.0.1:8931`) or a versioned base
(`http://127.0.0.1:8931/v1`) is normalized to the full chat-completions
endpoint the providers POST to, so a local proxy (recorder, gateway, cost
tracker) can be pointed at with its origin alone. Anything else — a full
endpoint, a custom gateway path, a URL with a query string — passes through
verbatim. The `copilot` provider's base URL is its API origin and is never
rewritten.

## Features

- OpenAI-compatible streaming completions
- OpenRouter model routing
- Ollama local inference
- Provider configuration and resolution
- Token counting and context window management

## Publishing

Tags matching `fa_llm-v*` trigger `.github/workflows/publish-fa-llm.yml`,
which publishes to pub.dev via OIDC (no tokens; pub.dev verifies the
GitHub identity).

**First publish of a new package is manual** (issue #1511): pub.dev OIDC
publishing can only upload new *versions* of an *existing* package, so the
very first upload must come from an authenticated owner:

1. `cd packages/fa_llm && dart pub publish` (logged-in user account).
2. On pub.dev: package admin → automated publishing → GitHub Actions,
   repo `IstiN/flutter_agent_harness`, workflow `publish-fa-llm.yml`,
   tag pattern `fa_llm-v*`.
3. Push the tag — the workflow takes over from there.

The workflow pre-flights this: it HEAD-probes
`https://pub.dev/api/packages/fa_llm` and fails with the actionable
message (exit code 10) if the package does not exist yet, instead of a
bare `Only users are allowed to upload new packages.` server error.
