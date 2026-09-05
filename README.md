# flutter_agent_harness

[![CI](https://github.com/IstiN/flutter_agent_harness/actions/workflows/ci.yml/badge.svg)](https://github.com/IstiN/flutter_agent_harness/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/flutter_agent_harness.svg)](https://pub.dev/packages/flutter_agent_harness)
[![CRAP max 8.0 — green zone](https://img.shields.io/badge/CRAP%20max-8.0-brightgreen)](https://github.com/IstiN/crap4dart)
[![coverage ≥ 80%](https://img.shields.io/badge/coverage-%E2%89%A5%2093%25-brightgreen)](https://github.com/IstiN/flutter_agent_harness)

Cross-platform AI agent harness for Dart and Flutter — streaming provider
adapters, an agent loop with native tool calling, JSONL session persistence,
context compaction, and a pi-like terminal coding agent (`fa`). Architecture
ported from [pi-mono](https://github.com/badlogicgames/pi-mono)
(`packages/ai` + `packages/agent`), with a pure-Dart core that runs on the
VM, Flutter desktop/mobile, and web.

**[fa1.dev](https://fa1.dev)** — the project website: a live in-browser
demo of the full agent (sandboxed shell, git, interpreters — your key
stays in page memory), the [iOS public
beta](https://testflight.apple.com/join/En1eC9UK) on TestFlight, the
[macOS app](https://github.com/IstiN/flutter_agent_harness/releases/latest),
and the CLI installer below.

## Design contract

- **Pure Dart core.** No `dart:io`, no Flutter imports in `lib/` — platform
  capabilities live behind abstractions (`ExecutionEnv`); the IO
  implementation is a separate entry point (`lib/io.dart`), so the core
  compiles for web.
- **Errors-as-events.** Providers never throw: network failures, 429s,
  malformed SSE — everything arrives as an `error` event with a stop
  reason. The agent loop never dies on a dropped connection.
- **Streaming-first, partial-first.** `Stream<AgentEvent>` everywhere;
  every delta event carries the live partial message.
- **Native tool calling** per provider (OpenAI `tools`, Anthropic
  `tool_use`, Google `functionCalling`). Prompt-based calling exists only
  as an opt-in adapter for chat-only runtimes.
- **Token accounting inline**, overflow detection per provider, and
  token-based (never message-count-based) context management.
- **Cancellation everywhere** via `CancelToken` — providers, loop, tools.

## What's inside

- **Agent core** (`lib/src/`): the async agent loop, steering + follow-up
  message queues (inject input mid-run), hooks (`beforeToolCall`,
  `afterToolCall`, `transformContext`, `prepareNextTurn`), model roles
  (`default`/`smol`/`slow`/`plan`) with fallback chains, API-key rotation,
  429 mid-turn take-over, and stream watchdogs (connect + idle timeouts
  with config overrides).
- **Providers**: openai-completions (covers OpenRouter/DeepSeek/Kimi/Grok/…),
  Anthropic, Google, ChatGPT (Codex OAuth), Copilot (device flow), DIAL,
  MiniMax, z.ai, CodeMie (SSO), Ollama, plus custom providers saved from
  the REPL. One OpenAI-compatible adapter is reused via `baseUrl` swap.
- **Sessions**: append-only JSONL trees (branching, labels, tree
  navigation with branch summaries), token-based auto-compaction with a
  structured summary prompt, and attached-session support (watch a live
  CLI session and hand it input from the Flutter app).
- **Tools**: `read` (trailing selectors, archives, SQLite), `write`, `ls`,
  `bash` (background jobs, timeout-retry for transient stalls, per-turn
  approval grants), `task` (parallel subagents with typed roles and
  output schemas), `lsp` (diagnostics/definition/references/rename),
  MCP servers (stdio + remote), A2A interop, `checkpoint`/`rewind`,
  `memory_*` (git-backed long-term memory), `ask`, `request_secret`.
- **Agent skills**: `<root>/<name>/SKILL.md` plus Claude/Copilot/Codex
  layouts (`.claude/skills`, `.github/skills`, `.codex/skills`, user-level
  equivalents) discovered by default with an access prompt; typed
  frontmatter (allowed-tools, paths, context: fork), `$ARGUMENTS`
  rendering, and per-turn approval grants. See
  [docs/migrating-from-claude-copilot-codex.md](docs/migrating-from-claude-copilot-codex.md).
- **Approval gate** (`lib/src/approval/`): read/write/exec tiers, session
  modes (always-ask/write/yolo/unattended), per-tool overrides, and a
  critical-pattern interceptor for dangerous `bash` — even in yolo.
- **Trajectory ledger** (`lib/src/trajectory/`): every session projects
  into an immutable snapshot (turns, timeline modes, full-text search)
  rendered by the `/trajectory` REPL family and the `fa trajectory`
  headless command.
- **Agent messaging**: every agent owns a file inbox in a shared fabric —
  two `fa` instances chat live; subagents are first-class addressable
  mailboxes. A2A (`fa serve --a2a`) mounts the agent as a remote endpoint.
- **Model-agnostic prompts** (`prompts/`): all LLM prompts are versioned
  Markdown with override support — no prompt strings buried in code.

## Install

```bash
curl -fsSL "https://fa1.dev/install.sh" | sh    # macOS / Linux / WSL
dart pub global activate flutter_agent_harness  # fa + fah on your PATH
```

The installer detects the OS/architecture, downloads a prebuilt binary
from the [latest GitHub
Release](https://github.com/IstiN/flutter_agent_harness/releases/latest),
puts it on your PATH, and (on macOS) strips Gatekeeper quarantine and
re-signs it. More install paths — the web demo, the Flutter app — live on
[fa1.dev](https://fa1.dev).

## CLI (`fa` / `fah`)

A pi-like terminal coding agent: a full-screen TUI (streaming markdown,
mouse wheel scrolling, slash-command completion, live steering) with the
same core as the library. Sessions persist under
`~/.fah/sessions/<cwd-slug>/`.

```bash
export OPENROUTER_API_KEY=sk-or-...   # or ANTHROPIC_API_KEY / GOOGLE_API_KEY
dart run bin/fah.dart                 # defaults: OpenRouter, claude-sonnet-4
dart run bin/fah.dart --provider anthropic --model claude-sonnet-4-5
dart run bin/fah.dart --model openai/gpt-4o-mini --cwd . --session-root /tmp/fah
```

Headless mode runs a single non-interactive prompt and exits — the response
streams to stdout, tool indicators and notices go to stderr (stdout stays
pipeable), nothing is ever prompted interactively, and the session persists
like a REPL run. Exit codes: 0 ok, 1 provider error, 130 aborted (Ctrl-C).
A first positional naming an existing file becomes the prompt source: text
files (`.md`, `.markdown`, `.txt`) are inlined as the prompt; any other
(binary) file is attached as a path reference for the agent's tools — in
both cases trailing text appends as the instruction. A path that does not
exist is treated as plain prompt text.

```bash
fa "summarize the changelog"      # positional prompt
fa -p "fix the typos in README.md"  # -p/--prompt alias
fa CHANGELOG.md "summarize this"  # text file as prompt
fa screenshot.png "describe it"   # binary → path reference
fa "summarize the changelog" | pbcopy  # pipes cleanly
```

Flags: `--model <id>`,
`--provider openai-completions|anthropic|google|dial|minimax|zai`,
`--base-url <url>`, `--cwd <dir>`, `--session-root <dir>`, `-p`/`--prompt
<text>`, `--help`, `--version`.

The `chatgpt` provider (Codex backend) is also available: sign in with a
ChatGPT account via `/provider chatgpt oauth` in the REPL (OAuth-only —
there is no headless `--provider chatgpt` flag). Several ChatGPT accounts
can coexist: the flow offers the saved accounts first, each account keeps
its own named entry and secure-store slot, and re-auth never touches a
sibling account's credentials.

### Env preconfig (Docker / headless)

`FA_PROVIDER_TYPE` + `FA_PROVIDER_CONFIG` boot a declared provider with
no saved config, and the declaration becomes the session default for
every model role (`default`/`smol`/`slow`/`plan`) — the same selection a
`/provider <name>` switch makes:

```bash
FA_PROVIDER_TYPE=zai
FA_PROVIDER_CONFIG='{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"glm-5.3","apiKeyEnvVar":"ZAI_API_KEY"}'
ZAI_API_KEY=sk-...
```

`baseUrl` and `model` are required — no catalog defaults fill gaps; a
missing field fails loud at boot. `apiKeyEnvVar` is optional: declared,
the named env var (or its `_BASE64` twin) must hold the key; omitted,
the provider boots keyless and the spec's usual env names are never
probed. Every text value has a base64 twin for CI platforms that mangle
special characters — `FA_PROVIDER_CONFIG_BASE64`, and
`<apiKeyEnvVar>_BASE64` for the key: the plain value wins when both
carry the same value; mismatched or malformed twins fail loud.

```bash
# base64 twin form (identical boot):
FA_PROVIDER_CONFIG_BASE64=$(printf '%s' "$FA_PROVIDER_CONFIG" | base64)
ZAI_API_KEY_BASE64=$(printf '%s' "$ZAI_API_KEY" | base64)
```

GitHub Copilot is a first-class provider. `/provider copilot` connects a
GitHub account via the device-code flow (open the shown
`verification_uri`, enter the `user_code`) or by pasting an existing PAT
— the flow works headless too — and the Flutter app offers the same
connect as a sheet. Accounts save as named entries (`copilot-<login>` by
default); the plan picks the host — individual `api.githubcopilot.com`,
business `api.business.githubcopilot.com`, enterprise
`api.enterprise.githubcopilot.com`, or a custom `--base-url` override —
and several accounts can coexist side by side. Tokens live only in the
OS secure store (Keychain / Secret Service); `config.yaml` carries name,
plan, and baseUrl, never a token. CI runs store-less via the
`FA_KEY_COPILOT_<NAME>` env (plus a `_2`… ring for more entries), and
headless runs take `--provider copilot --model <id>` with
`COPILOT_GITHUB_TOKEN`. Models come from a live `GET /models` (with
capabilities and limits). The device-flow client id is overridable via
`FA_COPILOT_CLIENT_ID` — that GitHub endpoint is undocumented, so a
custom client id carries an account-ban risk; override only with cause.

### Slash commands (selection)

`/provider`, `/models`, `/model`, `/approval`, `/allow`, `/tools`,
`/skills`, `/agents`, `/tasks`, `/trajectory [view|cost|tail|inspect]`,
`/memory [maintain]`, `/compact`, `/reset`, `/checkpoint`/`/rewind`,
`/mcp`, `/a2a`, `/dap`, `/stats`, `/mouse`, `/settings`, `/help` — plus
every discovered skill as `/skill:<name>` (a bare `/<name>` alias works
too). While a run streams, typed input steers the agent; Ctrl-C aborts
the current run (Ctrl-C at the idle prompt exits).

Tool calls pass the approval gate (see above); mode and always-allowed
tools persist in `~/.fah/config.yaml`. Tool availability can be scoped
per project/session via `.fah/config.yaml` and `.tools/<id>.yaml`
(see [docs/tool-availability.md](docs/tool-availability.md)).

The CLI core (`AgentCli` + `CliIO`) is pure Dart and lives in
`lib/src/cli/`; only `bin/fah.dart` and `lib/io.dart` touch `dart:io`.

## Agent-to-agent messaging (DAP)

The CLI ships a default-on DAP/1 hub plugin (`bin/fah_hub_plugin.dart` +
the hosted `fah_hub_client` pub package): agents connect to a hub over a signed
WebSocket, exchange end-to-end encrypted channel messages and DMs (the
hub only ever sees ciphertext), and see each other's presence. Inbound
hub mail is drained into the agent loop as steering messages; `/dap` and
the `dap_*` tools drive the connection. See [docs/dap.md](docs/dap.md)
for the protocol, the hub server, and an end-to-end setup walkthrough.

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
