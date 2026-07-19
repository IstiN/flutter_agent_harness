# flutter_agent_harness

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
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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

## CLI (`fah`)

A pi-like terminal coding agent ships in `bin/fah.dart`: a REPL with the
built-in `read` / `write` / `ls` / `bash` tools, JSONL session persistence
under `~/.fah/sessions` (cwd-encoded layout), automatic context compaction,
and slash commands.

```bash
export OPENROUTER_API_KEY=sk-or-...   # or ANTHROPIC_API_KEY / GOOGLE_API_KEY
dart run bin/fah.dart                 # defaults: OpenRouter, claude-sonnet-4
dart run bin/fah.dart --provider anthropic --model claude-sonnet-4-5
dart run bin/fah.dart --model openai/gpt-4o-mini --cwd . --session-root /tmp/fah
```

Flags: `--model <id>`, `--provider openai-completions|anthropic|google`,
`--base-url <url>`, `--cwd <dir>`, `--session-root <dir>`, `--help`,
`--version`.

Slash commands inside the REPL: `/exit`, `/reset` (new session), `/compact`
(summarize history now), `/stats` (token/cost totals), `/model <id>` (show or
switch model), `/approval [always-ask|write|yolo]` (tool approval mode),
`/allow [tool]` (always-allow a tool), `/help`. While a run is streaming,
typed input is steered into the agent; Ctrl-C aborts the run (Ctrl-C at the
idle prompt exits).

Tool calls pass an approval gate (`lib/src/approval/`): every tool has a
capability tier (read/write/exec; exec for undeclared custom tools), the
session mode decides what runs unattended, and per-tool overrides plus a
critical-pattern interceptor for `bash` (e.g. `rm -rf /`, fork bombs,
`curl … | sh`) can force a prompt — even in `yolo`. The prompt UI is an
injectable callback; piped (non-interactive) input denies prompt-policy
calls with a reason. Mode and always-allowed tools persist in
`~/.fah/config.yaml`.

The CLI core (`AgentCli` + `CliIO`) is pure Dart and lives in
`lib/src/cli/agent_cli.dart`; only `bin/fah.dart` and `lib/io.dart` touch
`dart:io`.


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
