# CLI

The `fah` / `fa` CLI (`bin/fah.dart`). Related: [providers.md](providers.md) for the provider catalog, [project-layout.md](project-layout.md) for the broader codebase.

## Top-level

- `bin/fah.dart` — the `fah`/`fa` CLI. REPL (no args) or headless (`fa "prompt"`/`-p`, mutually exclusive). First positional naming an EXISTING file is the prompt source (`.md`/`.txt` inlined, others attached by reference; `-p` is verbatim). Args parsed in `lib/src/cli/cli_args.dart` (pure Dart). Headless: exit 0/1/130; `CliIO` contract — `write` = primary stream, `writeln` = diagnostics (stderr headless). TUI leaves the mouse to the terminal by default (native select-to-copy); `FA_TUI_MOUSE=1` (`AgentCliConfig.tuiMouseCapture`) captures it for wheel scrolling.

## REPL machinery

- `lib/src/cli/` — REPL machinery: `/provider [name] [baseUrl] [token] | custom` (guided wizard in `provider_flow.dart` + `provider_commands.dart`), custom providers in `customProviders:` section of `~/.fah/config.yaml`. `/models` also manages `models:` section: `/models config`/`set <slot> <model> [baseUrl]`/`remove <slot>` (persisted via `onModelsConfigChanged`), `/model <name>` resolves `models.custom`. Keys: env first, then secure store (`lib/src/secrets/secure_key_store*.dart` — Keychain/Secret Service/PasswordVault, IO backends only in `lib/io.dart`), preloaded into `SecureKeyCache`. DEFAULT endpoint resolves env → `FA_KEY_<HOST>` → `FA_KEY_<HOST>_<NAME>` → legacy; other endpoints resolve ONLY scoped store keys; `/key set` writes store-only. ALL TUI pickers have type-to-filter + backspace. Provider→model pick flows in `lib/src/cli/settings_flow.dart` NAMED `SettingsFlow` extension (public `runProviderModelFlow`/`startChatModelFlow`/`startMediaSlotFlow`/`startAgentModelFlow`). Model-list fetch dispatches per dialect (`_fetchProviderModelIds`):

| spec | endpoint | auth |
| --- | --- | --- |
| CodeMie (URL marker) | `/llm_models` | saved entry's own key |
| DIAL (`provider: 'dial'`) | `/openai/models` | `Api-Key` header |
| else | OpenAI `/models` | env / scoped store |

Failures fall back to manual entry. `startAgentModelFlow` pins the `smol`/`subagent` role chains through `ModelRolesResolver.setRoleChain`/`clearRoleChain` (the resolver is created on demand when the config had no `roles:` section — `AgentCliConfig.modelRolesResolver` is mutable) and persists via `onModelsConfigChanged` (`bin/fah.dart`'s `persistConfig` reads the live resolver config).

- `lib/src/prompts/prompt_overrides.dart` — `prompts:` config section maps prompt names to file path or inline text; strict validation; flags `--system-prompt(-file)` > config > built-in.
- `lib/src/cli/cli_help.dart` — full `fah --help` text, guarded by `test/cli/cli_help_test.dart` (update BOTH).
- `lib/src/web_search/` — `web_search` (DDG keyless → Brave/Tavily keyed) and `web_fetch` (HTML→markdown, pub.dev handler) via `builtinTools(env, webSearch:)`.
- `lib/src/model_roles/provider_catalog.dart` — provider table (incl. `chatgpt` Codex-backend `chatgpt-codex`); specs default `input: ['text','image']` (vision). `FA_PROVIDERS` dart-define / runtime env (`providerFilterEnvOverride`, wired from process env in `bin/fah.dart`; define wins) allowlists per build — `enabledProviders`/`providerEnabledInBuild`/`catalogProvider` honor it, default everything on (`test/build_filter/provider_filter_test.dart`).

## Provider catalog (CLI auth flows)

See [providers.md](providers.md) for the full provider catalog with auth mechanisms, endpoint patterns, and CLI flags.

## `/settings` hub

Interactive TUI picker; line mode prints a summary. Entries launch the same flows the dedicated slash commands open:

| Entry | Slash command |
| --- | --- |
| Provider | `/provider` |
| Edit / delete provider | `/provider` edit / delete |
| Chat model | `/model` |
| Model parameters | `/settings model_params` |
| Media models | `/models` |
| Agent models | `/models` (agent roles) |
| Approval mode | `/approval` |
| Agent mode | `/agent` |
| API keys | `/key` |
| MCP servers | `/mcp` |
