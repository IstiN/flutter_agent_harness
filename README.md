# flutter_agent

Cross-platform AI agent harness for Dart and Flutter — streaming provider
adapters, an agent loop with native tool calling, JSONL session persistence,
and context compaction. Architecture ported from
[pi-mono](https://github.com/badlogicgames/pi-mono) (`packages/ai` +
`packages/agent`), with a pure-Dart core that runs on the VM, Flutter
desktop/mobile, and web.

> **Status: early development (Phase 0).** See [GOAL.md](GOAL.md) for the
> roadmap, quality gates, and design contract. The API is not yet stable.

## Highlights (target design)

- **Streaming-first**: `Stream<AgentEvent>` from every provider, partial-first
  deltas — each event carries the current partial message.
- **Errors-as-events**: providers never throw; failures arrive as `error`
  events with a `stopReason`, so the agent loop never dies on a 429 or a
  dropped connection.
- **Native tool calling** (OpenAI tools, Anthropic tool_use, Google
  functionCalling) — no prompt-based JSON scraping.
- **Token-based context management**: inline usage accounting, overflow
  detection, LLM-powered compaction.
- **Sessions as append-only JSONL trees** behind a storage abstraction —
  portable to web and mobile.
- **Cancellation everywhere** via `CancelToken`.

## Usage (current seed)

```dart
import 'package:flutter_agent/flutter_agent.dart';

void main() async {
  final source = CancelTokenSource();

  // Pass source.token into any long-running operation.
  final cancelled = source.token.onCancel.then((_) => print('aborted'));

  source.cancel('user pressed stop');
  await cancelled;
}
```

Provider adapters and the agent loop land in the next phases — see the
roadmap in [GOAL.md](GOAL.md).

## Development

```bash
dart pub get
dart test --coverage=coverage --exclude-tags integration
dart run coverage:format_coverage --lcov -i coverage -o coverage/lcov.info
python3 scripts/check_coverage.py
```

Pre-commit hook (analyze + tests + coverage ≥ 80% + duplication < 1%):

```bash
cp scripts/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

## License

MIT — see [LICENSE](LICENSE).
