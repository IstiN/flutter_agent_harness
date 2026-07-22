# Changelog

## 0.1.0

- Initial project setup: package skeleton, quality gates (analyze, tests,
  coverage ≥ 80%, duplication < 1%), GOAL.md with the pi-mono port roadmap.
- Seeded `CancelToken` / `CancelTokenSource` / `CancelledException` — the
  universal cancellation primitive (Dart counterpart of web `AbortSignal`).

## 0.1.1


- Ported pi-mono `packages/ai`: EventStream contract (partial-first deltas,
  errors-as-events), SSE line decoder, openai-completions (OpenRouter-ready),
  Anthropic and Google provider adapters, usage/cost accounting,
  context-overflow detection, `Retry-After` parsing.
- Ported pi-mono `packages/agent`: low-level agent loop, stateful `Agent`
  with steering/follow-up queues and hooks, `AgentTool` registry with
  JSON-schema param validation.
- Sessions and context management: `ExecutionEnv` abstraction (pure-Dart
  memory impl + `dart:io` impl in `lib/io.dart`), append-only JSONL session
  tree with branching/labels, token estimation and LLM compaction pipeline.
- CLI harness (`bin/fah.dart`): a pi-like terminal agent with built-in
  `read`/`write`/`ls`/`bash` tools on the `ExecutionEnv` abstraction
  (`lib/src/tools/builtin_tools.dart`), a pure-Dart REPL core with injectable
  IO (`lib/src/cli/agent_cli.dart`) — live streaming output, slash commands
  (`/exit`, `/reset`, `/compact`, `/stats`, `/model`, `/help`), steering,
  Ctrl-C abort, JSONL session persistence, and auto-compaction.

## 0.1.2

- test(providers): Ollama Cloud live integration tests (gpt-oss:20b default, OLLAMA_MODEL override)
- ci: create placeholder .env for the example app (asset_does_not_exist)
- fix(example): mobile sessions no longer land in a doubled host path
- ci: fix quality gate — install Flutter SDK + example pub get for repo-wide analyze
- ci: auto-release on push to main (patch bump + tag, OIDC publish) + OLLAMA_API_KEY in integration env
- feat(example): file browser panel (tree + preview, collapsible on wide screens)
- test(providers): live integration tests (OpenRouter live, Anthropic/Google key-gated)
- feat(sandbox): pip-lite for sandbox python (pure-python wheels)
- feat(sandbox): lua interpreter (WASI) in the mobile shell
- feat(sandbox): small utils batch (tree, file, xz/bzip2 -d, base64+hashes on web)
- feat(sandbox): ssh/scp/sftp exec builtins via dartssh2
- feat(sandbox): nslookup/dig + whois network diag builtins
- feat(sandbox): diff/patch builtins (Dart, iOS+web)
- feat(secrets): env injection + redaction (SecretsStore)
- feat(sandbox): web command parity with iOS shell
- feat(example): python3/qjs on web via CDN interpreters + copy-session button
- chore: remove ssh debug script
- feat(sandbox): sqlite3 CLI (WASI build from official amalgamation)
- style: curly braces in web_git remote add (lint info)
- feat(web): local git in the browser sandbox (MemoryShell)
- feat(sandbox): QuickJS JavaScript engine (qjs/js) + web parity checks
- feat(sandbox): python3 (CPython 3.14 WASI) in the mobile shell
- feat(tools): edit (str_replace) tool + sandbox path mapping + coding system prompt
- feat(git): push over smart HTTP (receive-pack) + SSH transport (dartssh2)
- feat(git): remote/fetch subcommands, checkout -b, branch -r, clone fixes
- fix(mobile shell): curl/wget --version, --help, and no-URL error message
- feat(git): smart HTTP git-upload-pack clone for any public remote
- feat(web): pure-Dart MemoryShell for the browser + flutter build web fixed
- feat(mobile shell): cd/export/unset, $VAR expansion, grep/wget, du/stat/tac/expr/id/relpath builtins
- feat(mobile shell): add git support via dart-git + GitHub archive clone
- feat(mobile shell): add dart-native curl/jq/yq builtins
- feat(mobile shell): add WASM sed/awk/tar/gzip/zip+unzip, env builtin, redirect capture fix, POSIX double-quote escapes
- feat(mobile shell): add shell builtins (test, which, whoami, xargs, command -v)
- chore: remove stray temp files accidentally committed
- test: add shell command integration tests (host + WASM sandbox catalog)
- fix(ls tool): return basename when path points to a file
- fix(ios): get WASM shell working on iOS simulator
- feat(example): replace busybox with permissive uutils/ripgrep WASM sandbox
- feat(example): sandboxed WASM bash shell for mobile/web via busybox+wasm_run
- fix(example): cache streaming/error state in ChatScreen for immediate UI updates and add multi-turn test
- fix(example): notify UI before persisting so streaming indicator hides immediately
- fix(example): throttle and incrementally sync messages to avoid SliverAnimatedList crash
- fix(example): move input bar outside Chat widget to fix layout and semantics
- fix(example): replace package Composer with custom input bar to fix ParentDataWidget crash
- feat(flutter_example): integrate flutter_chat_ui with markdown and tool cards
- feat(flutter_example): load API key from .env for simulator runs
- fix(flutter): typing indicator, error banner, 90s timeout; feat(cli): persist last model/provider/mode in ~/.fah/config.yaml
- Add Flutter mobile example with path_provider + LocalExecutionEnv
- Add pi-style agent modes and prompt templates to CLI
- Clean lint info in plugin tests
- Update GOAL.md with plugin/package extension API
- Add plugin/package extension system with built-in inspect_image plugin
- Add inspect_image tool: dedicated vision model analysis like pi-inspect-image
- Add fah/fa executables, rebrand system prompt, image support in read tool
- Add CLI harness: bin/fah REPL with builtin tools, sessions, compaction
- Format codebase, fix lint info, shorten pubspec description (pana 160/160); add format gate to pre-commit
- CI: GitHub Actions quality gates + OIDC pub.dev publish on version tags
- Phase 3: token estimation and LLM compaction pipeline
- Phase 3: ExecutionEnv abstraction and append-only JSONL session tree
- Phase 2: AgentTool registry with JSON-schema param validation
- Phase 2: stateful Agent with steering/follow-up queues and hooks
- GOAL.md: TDD for new code, coverage target >90%, push after every card
- Phase 2: port low-level agent loop with AgentEvent stream and CancelToken abort
- Phase 1: context-overflow detection, Retry-After parsing, sealed exception hierarchy
- Phase 1: port Google provider adapter with native functionCalling streaming
- Phase 1: port Anthropic provider adapter with native tool_use/thinking streaming
- Phase 0: port openai-completions provider adapter (OpenRouter-ready) with errors-as-events and CancelToken abort
- Phase 0: port AssistantMessageEventStream contract and SSE line decoder from pi-mono
- GOAL.md: allow agent publishing on explicit user instruction; OIDC for tagged releases

## 0.1.3

- ci: fix auto-release tag push — annotated tag + --atomic (lightweight tags are not sent by --follow-tags)
- test(providers): Ollama Cloud live integration tests (gpt-oss:20b default, OLLAMA_MODEL override)
- ci: create placeholder .env for the example app (asset_does_not_exist)
- fix(example): mobile sessions no longer land in a doubled host path
- ci: fix quality gate — install Flutter SDK + example pub get for repo-wide analyze
- ci: auto-release on push to main (patch bump + tag, OIDC publish) + OLLAMA_API_KEY in integration env
- feat(example): file browser panel (tree + preview, collapsible on wide screens)
- test(providers): live integration tests (OpenRouter live, Anthropic/Google key-gated)
- feat(sandbox): pip-lite for sandbox python (pure-python wheels)
- feat(sandbox): lua interpreter (WASI) in the mobile shell
- feat(sandbox): small utils batch (tree, file, xz/bzip2 -d, base64+hashes on web)
- feat(sandbox): ssh/scp/sftp exec builtins via dartssh2
- feat(sandbox): nslookup/dig + whois network diag builtins
- feat(sandbox): diff/patch builtins (Dart, iOS+web)
- feat(secrets): env injection + redaction (SecretsStore)
- feat(sandbox): web command parity with iOS shell
- feat(example): python3/qjs on web via CDN interpreters + copy-session button
- chore: remove ssh debug script
- feat(sandbox): sqlite3 CLI (WASI build from official amalgamation)
- style: curly braces in web_git remote add (lint info)
- feat(web): local git in the browser sandbox (MemoryShell)
- feat(sandbox): QuickJS JavaScript engine (qjs/js) + web parity checks
- feat(sandbox): python3 (CPython 3.14 WASI) in the mobile shell
- feat(tools): edit (str_replace) tool + sandbox path mapping + coding system prompt
- feat(git): push over smart HTTP (receive-pack) + SSH transport (dartssh2)
- feat(git): remote/fetch subcommands, checkout -b, branch -r, clone fixes
- fix(mobile shell): curl/wget --version, --help, and no-URL error message
- feat(git): smart HTTP git-upload-pack clone for any public remote
- feat(web): pure-Dart MemoryShell for the browser + flutter build web fixed
- feat(mobile shell): cd/export/unset, $VAR expansion, grep/wget, du/stat/tac/expr/id/relpath builtins
- feat(mobile shell): add git support via dart-git + GitHub archive clone
- feat(mobile shell): add dart-native curl/jq/yq builtins
- feat(mobile shell): add WASM sed/awk/tar/gzip/zip+unzip, env builtin, redirect capture fix, POSIX double-quote escapes
- feat(mobile shell): add shell builtins (test, which, whoami, xargs, command -v)
- chore: remove stray temp files accidentally committed
- test: add shell command integration tests (host + WASM sandbox catalog)
- fix(ls tool): return basename when path points to a file
- fix(ios): get WASM shell working on iOS simulator
- feat(example): replace busybox with permissive uutils/ripgrep WASM sandbox
- feat(example): sandboxed WASM bash shell for mobile/web via busybox+wasm_run
- fix(example): cache streaming/error state in ChatScreen for immediate UI updates and add multi-turn test
- fix(example): notify UI before persisting so streaming indicator hides immediately
- fix(example): throttle and incrementally sync messages to avoid SliverAnimatedList crash
- fix(example): move input bar outside Chat widget to fix layout and semantics
- fix(example): replace package Composer with custom input bar to fix ParentDataWidget crash
- feat(flutter_example): integrate flutter_chat_ui with markdown and tool cards
- feat(flutter_example): load API key from .env for simulator runs
- fix(flutter): typing indicator, error banner, 90s timeout; feat(cli): persist last model/provider/mode in ~/.fah/config.yaml
- Add Flutter mobile example with path_provider + LocalExecutionEnv
- Add pi-style agent modes and prompt templates to CLI
- Clean lint info in plugin tests
- Update GOAL.md with plugin/package extension API
- Add plugin/package extension system with built-in inspect_image plugin
- Add inspect_image tool: dedicated vision model analysis like pi-inspect-image
- Add fah/fa executables, rebrand system prompt, image support in read tool
- Add CLI harness: bin/fah REPL with builtin tools, sessions, compaction
- Format codebase, fix lint info, shorten pubspec description (pana 160/160); add format gate to pre-commit
- CI: GitHub Actions quality gates + OIDC pub.dev publish on version tags
- Phase 3: token estimation and LLM compaction pipeline
- Phase 3: ExecutionEnv abstraction and append-only JSONL session tree
- Phase 2: AgentTool registry with JSON-schema param validation
- Phase 2: stateful Agent with steering/follow-up queues and hooks
- GOAL.md: TDD for new code, coverage target >90%, push after every card
- Phase 2: port low-level agent loop with AgentEvent stream and CancelToken abort
- Phase 1: context-overflow detection, Retry-After parsing, sealed exception hierarchy
- Phase 1: port Google provider adapter with native functionCalling streaming
- Phase 1: port Anthropic provider adapter with native tool_use/thinking streaming
- Phase 0: port openai-completions provider adapter (OpenRouter-ready) with errors-as-events and CancelToken abort
- Phase 0: port AssistantMessageEventStream contract and SSE line decoder from pi-mono
- GOAL.md: allow agent publishing on explicit user instruction; OIDC for tagged releases

## 0.1.4

- chore: mark fake PEM stubs as false_secrets for pub validation

## 0.1.5

- refactor(prompts): extract LLM prompts to prompts/*.md + codegen (AGENTS.md convention)

## 0.1.6

- feat(site): GitHub Pages landing + live web demo with BYOK
- feat(example): BYOK connection settings with provider presets

## 0.1.7

- fix(example): sharpen Ollama Cloud CORS guidance in BYOK notes

## 0.1.8

- feat(site): SEO/GEO pack + OG share image

## 0.1.9

- feat(example): web file upload + IndexedDB-persisted sandbox FS

## 0.1.10

- feat(site): capability comparison table (Browser/macOS/iOS/Android/Windows)

## 0.1.11

- feat(example): WebLLM on-device provider for the web demo (no API key needed)

## 0.1.12

- feat(example): full WebLLM preset list matching flutter_agent_memory (22 models)

## 0.1.13

- feat(example): dark theme matching the landing (terminal aesthetic)

## 0.1.14

- feat(example): branded web loading splash (first-frame fade)

## 0.1.15

- feat(example): WebLLM function calling (tools for Hermes-3 FC preset)

## 0.1.16

- feat(example): left sidebar (model picker + sessions), files move right

## 0.1.17

- feat(example): custom provider management + WebLLM model cache management in settings

## 0.1.18

- feat(example): Gemma 4 on-device provider via flutter_gemma (iOS/Android)

## 0.1.19

- fix(example): settings dialogs adapt to narrow phone screens

## 0.1.20

- feat(core): prompt-based tool-calling wrapper (universal chat-model tools)

## 0.1.21

- feat(example): Gemma provider on web via flutter_gemma litert-lm web (Gemma 4 tools in-browser)

## 0.1.22

- refactor(example): WebLLM goes chat-only + universal prompt-tools wrapper

## 0.1.23

- feat(example): markdown/HTML file previews + auto-refresh on agent file mutations

## 0.1.24

- feat(example): brand app icon for all platforms (gradient >_ mark)

## 0.1.25

- ci: coalesce auto-releases to <=1 per 2h + scheduled catch-up

## 0.1.26

- fix(example): Gemma web uses -web.litertlm builds + Gemma cache management in settings

## 0.1.27

- feat(example): transformers.js Gemma provider on web (ONNX q4f16, tools via prompt wrapper)
- feat(brand): rename visible brand to Fa + app favicon matches the site

## 0.1.28

- feat(example): central sandbox command registry drives the Fa system prompt
- fix(example): web upload fix + chat uploads→uploads/ + light HTML preview + session delete

## 0.1.29

- fix(example): transformers.js download filter+progress, SVG/upload/attach UX, provider-error robustness

## 0.1.30

- feat(example): WebLLM presets refresh — Qwen3.5 + Qwen2.5-Coder (web-llm 0.2.84)
- feat(example): visible app name is Fa (assistant label, AppBar, transcript, system prompt)

## 0.1.31

- feat(tools): hashline edit format with content-hash anchors (omp port)
- feat(core): approval tiers with per-tool policy, bash interceptor, CLI/app prompt UIs
- feat(example): model lineup — drop <1.5GB presets, add Gemma 4 E4B ONNX (~5.2GB)

## 0.1.32


- feat(tools): web_search with provider chain (DDG keyless first, Brave/Tavily behind secrets) + web_fetch markdown extraction with a pub.dev site handler

## 0.1.33

- feat(tools): read selector grammar (:A-B, :A+C, multi-range, :raw) + zip inner paths + SQLite reads
- feat(tools): image read parity with pi (byte cap, pass-through, EXIF, placeholders) + transcribe_audio tool
- feat(site): set GA4 measurement ID

## 0.1.34

- feat(tools): task tool — parallel subagents with schema-validated results (omp port)
- feat(agent): TTSR stream rules — abort, inject, retry mid-generation (omp port)
- feat(providers): model roles (default/smol/slow/plan) with fallback chains, key rotation, path overrides

## 0.1.35

- feat(example): persist last connection + downloaded-models quick start on setup screen
- feat(tools): lsp tool backed by the Dart analysis server (diagnostics/definition/references/rename)

## 0.1.36

- fix(example): WebLLM context windows sized for the Fa system prompt + compaction scales with model window
- feat(cli): headless mode — fa "prompt", -p alias, file-as-prompt (md/txt content, binary path ref)

## 0.1.37

- fix(example): halve ONNX Gemma context window to 2048 (WebGPU OOM mitigation)
- feat: optional API token for custom providers (local servers need no key)
- feat(cli): banner shows baseUrl+key status, connection-refused hint, version in --help
- chore(example): ignore Firebase config files with real API keys
- fix(site): full-width header background and Fa branding
- feat(example): release prep — Fa branding, icons, bundle IDs, Firebase Analytics
- feat(cli): prompt overrides (config prompts: + --system-prompt[-file]) and full --help reference

## 0.1.38

- feat(site): Windows PowerShell installer + generated menus from install-config.yaml
- chore(macos): set bundle identifier to dev.fa1.macos and update copyright
- fix(site): use correct GA4 measurement ID (G-0Z3SW38FYC) and Fa mobile app label
- fix(ios): graceful WASM fallback — app starts without wasm shell on iOS
- feat(prompt-tools): slim on-device system prompt — compact schemas + fewer tools
- feat(cli): modern TUI pack — ! shell commands, /models filter, status line
- chore(site): switch GA measurement ID to Firebase web stream
- feat(cli): interactive installer with progress bar, provider/model picker, and config setup
- fix(example): readable ONNX/WebGPU crash messages + verified engine recovery

## 0.1.39

- feat(cli): Pi-style terminal banner, status bar, and /help filtering
- fix(site,install): remove DMTools from install dropdown and reword PATH symlink comment
- fix(install): make fa available immediately after install without shell reload
- feat(site): add DMTools install options to site dropdown
- fix(example): split SandboxPlatform.mobile into android/ios and disable shell command ads on iOS
- refactor(install): split installer into non-interactive install + interactive setup wizard
- fix(cli,install): primary command is fa, auto-add pub-cache to PATH
- fix(site): cache-bust web demo assets on every deploy
- fix(example): render user messages through the harness loop
- fix(site): mktemp compatibility on macOS

## 0.1.40

- fix(vendor): force-load wasm_run static lib via podspec and refresh Podfile.lock
- refactor(site): centralize installer banner/recipe in install-config.yaml and use DMTools-style Windows PATH
- fix(vendor): apply iOS wasm_run_flutter static-library linker flags in Podfile
- feat(cli): numbered line-mode slash menu and guard TUI to interactive TTYs
- fix(vendor): iOS wasm_run_flutter static library fallback
- fix(install): use github releases/latest/download direct URLs, avoid API rate limits
- feat(ci): build native fa binaries for win/mac/linux and download them in installers
- feat(ios): enable WASM shell via statically linked executable
- fix(site): repair install dropdown visibility and bust cache; make CLI raw-mode fallback graceful
- feat(cli): add named session management via --session and /session commands
- feat(cli): raw-mode TUI with slash menu, model picker, and dynamic version
- feat(site): add Windows cmd.exe installer wrapper (install.bat)

## 0.1.41

- fix(site): quote install URLs for zsh glob safety; refine iOS wasm_run static-library flags
- fix(cli): avoid double stdin subscription in TUI REPL
- fix(example): use DynamicLibrary.process for iOS wasm_run static linking

## 0.1.42

- feat(cli): dart_tui interactive TUI with markdown rendering
- ci: add build-mobile.yml (APK/iOS) and build-macos.yml (DMG) workflows
- feat: multi-session support — AgentSessionManager (core) + FlutterSessionManager (app)
- fix(example): hide empty assistant bubbles in chat
- feat(example): debug-log system prompt platform and WASM runtime setup
- docs(example): drop stale no-WASM-on-iOS comments after static linking fix
- fix(example): iOS gets the full WASM sandbox command set in the system prompt

## 0.1.43

- feat: agent skills + project context files (all platforms)
- feat(cli): background subagents via the task tool
- fix(cli): keep cursor pinned to input while the spinner ticks
- ci: create GitHub Release before binary upload + embed version

## 0.1.44

- ci: fix Windows binary build + installer mojibake

## Unreleased
