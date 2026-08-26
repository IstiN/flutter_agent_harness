# Changelog

## 0.1.205

- fix(cli): TUI renders rows in terminal cells (grapheme clusters) - markdown
  no longer slides after emoji/CJK; status row padding and menu truncation are
  cell-width aware; output history cap raised 200 -> 2000 (fence-safe replay).
- feat(cli): `unattended` approval mode - auto-approve everything including
  critical bash patterns, for runs without a user present; yolo regains its
  critical-pattern safety net.
- feat(cli): approval prompts accept a typed note and deliver it to the agent
  as steering feedback alongside the decision.
- fix(cli): empty assistant responses retry once with a 'continue' nudge
  (loop-level `maxEmptyRetries`); errors/aborts never trigger it.
- feat(session): incremental message persistence (crash-safe appends);
  sessions with persisted records survive empty-session cleanup.
- fix(cli): status meter tracks streaming thinking/tool-call sizes; session
  switches reset tok/cost/turn; failed runs keep the last real ctx anchor.
- feat(cli): skills access defaults to granted (opt-out); bare `/skills
  access` opens an interactive picker; disabled-skills hints on listings;
  `/skills` dispatch decomposed for the CRAP ratchet.
- fix(providers): OpenRouter OAuth keys persist endpoint-scoped
  (`FA_KEY_OPENROUTER_AI`) and the auth picker offers the stored key first.
- feat(tui): mouse capture defaults ON (two-finger scroll); `FA_TUI_MOUSE=0`
  opts out.
- test(cli): waitForIt poll budget 2s -> 25s (coverage runs on loaded boxes).


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

## 0.1.45

- feat(cli): fa update and fa uninstall quick commands
- fix(ci): quote pwsh run line — leading & parsed as a YAML anchor, breaking the whole workflow
- fix(windows): fa crash after TUI exit + installer mojibake
- ci: installer-smoke job runs the one-line installers on every tag

## 0.1.46

- fix(example): manual code signing with Fa Profile for CI iOS builds
- ci: placeholder firebase_options.dart for the repo-wide analyze
- chore(example): untrack leftover Firebase configs from the pre-migration path
- ci: cd /tmp before wiping the workspace in mirror checkout
- ci(pages): tracked firebase_options template instead of git history
- ci: self-updating mirror checkout in build-mobile.yml (same as build-macos)
- ci(pages): placeholder firebase_options.dart for the web build
- fix(example): keep Firebase Analytics from killing web startup
- ci: quote pwsh run line breaking the ci.yml YAML parse
- feat(example): unify bundle id to dev.fa1.app for a single App Store record
- feat(cli): /provider runtime switching and OS secure key storage (/key)
- fix(install): POSIX-clean install.sh and setup.sh for Ubuntu dash
- docs: document app build/TestFlight workflows and secrets in AGENTS.md
- ci: TestFlight submission for iOS and macOS (learn.ai pattern)
- refactor(example): migrate example/flutter_example to flutter_app (fa package)

## 0.1.47

- ci: explicit export-options plist for iOS builds (UUID + full identity)
- fix(example): pin the full signing identity name for iOS CI builds
- fix(example): pin CODE_SIGN_IDENTITY iPhone Distribution for CI builds

## 0.1.48


- feat(cli): guided custom provider setup (`/provider custom`): api type
  (openai/anthropic/google-like), base URL, optional key (saved to the OS
  secure store), then the model — picked from the endpoint's `/models`
  list or typed manually; the TUI provider picker gains `+ custom
  provider…`. (Code landed inside 7082bc8, swept up by a parallel commit.)

## 0.1.49

- ci(ios): fix signing identity extraction
- ci(ios): use fastlane build_only with temporary keychain
- ci(ios): use persistent ci.keychain on self-hosted runner
- ci(ios): use only build.keychain as default/search list, no OTHER_CODE_SIGN_FLAGS
- ci(ios): import distribution cert into login.keychain and build without isolated keychain
- ci(ios): download Apple WWDR G3 intermediate into build.keychain
- ci(ios): import WWDR intermediate into build.keychain, keep it unlocked, pass --keychain
- ci(ios): pass --keychain to codesign via OTHER_CODE_SIGN_FLAGS and add debug output

## 0.1.50

- ci(ios,macos): fallback to GitHub release for WasmRun iOS framework
- ci(ios,macos): restore WasmRun frameworks from local runner copy
- ci(ios): restore WasmRun.xcframework from pub cache before build
- fix(ios): use SRCROOT-relative path for wasm_run force_load
- ci(macos): set working-directory for flutter steps and create .env placeholder
- fix(ios): use absolute path for wasm_run force_load in Podfile
- fix(ios): force-load wasm_run via Podfile post_install for Runner target
- test(cli): wizard/registry coverage, help keyword, docs
- fix(ios): force-load wasm_run in pod target only
- fix(ios): use PODS_ROOT path for wasm_run force-load
- fix(ios): force-load wasm_run static lib for arm64
- ci(ios): create placeholder .env asset for build
- chore(ios): track firebase_options.dart for CI builds
- feat(cli): custom provider registry, guided wizard menus, TUI follow latch
- ci(ios): download missing iOS platform before build
- ci(ios): use simulator build to avoid missing device sdk
- ci(ios): boot simulator before flutter build to avoid attached device
- ci(ios): fix simctl invocation in fastlane build_only

## 0.1.51

- ci(ios,macos): fix artifact downloads and macOS keychain password
- ci(ios,macos): fix artifact path, macOS framework restore, action versions

## 0.1.52

- ci(ios): use absolute IPA path for TestFlight submit
- ci(ios,macos): fix submit artifact path and macOS Ruby PATH

## 0.1.53

- ci(macos): fix provisioning profile entitlement extraction
- fix(cli): rewind context crash and sticky echo duplication
- ci(macos): fix provisioning profile entitlement key
- fix(cli): enable mouse-wheel scrolling in TUI transcript
- ci(macos): fix entitlements heredoc syntax
- fix(cli): long user messages in TUI — ellipsis marker, calm scroll hint
- ci(macos): embed provisioning profile, use git tags for version
- fix(cli): degrade keychain write failures to session-only, never crash
- fix(macos): raise deployment target to 12.0 for TestFlight
- fix(macos): add LSApplicationCategoryType for TestFlight validation

## 0.1.59

- fix(ios): use development provisioning profile for Debug builds
- ci: unblock releases — vendor gitignore rule, pubspec catch-up, tag-ahead release
- test(example): drop the unused accessGranted param (CI fatal-warnings)
- feat: widen shell PATH for GUI apps (Homebrew python/node)

## 0.1.60

- fix(ios): export wasm_run FFI symbols so Release/TestFlight builds keep them
- ci: whitelist the tracked Firebase config for pub.dev's leak scanner

## 0.1.63

- test(example): end-to-end render test for the calculator demo app
- feat(example): JS apps platform in the Fa app (js_widget_runtime)
- docs: document the wasm_run symbol gate, strip-style pitfall, and new CI secrets/caches

## 0.1.64

- fix(ios,macos): keep -exported_symbol out of Debug link flags

## 0.1.65

- feat(example): teach the js-apps skill how to test apps before handover
- fix(example): fit the on-device Gemma context instead of engine overflow
- test(example): tap test — calculator key reaches the JS engine
- fix(cli): never hang on a keychain system modal
- fix(example): bundle demo app assets — nested asset dirs need explicit entries

## 0.1.66

- feat(example): stream model thinking live into the chat
- fix(example): replace the whole-run timeout with an idle watchdog
- feat(example): SVG app icons for JS apps
- feat(example): restore persisted sessions in the sidebar after restart

## 0.1.67

- feat(example): UX batch — collapsible tool output, Fa mark, in-app work bar
- test(example): textField onChange delivers typed text to JS
- fix(example): render attached-image messages — add the missing imageMessageBuilder

## 0.1.68

- feat(cli): render provider error lines in red
- fix(cli): hide the physical cursor while a run streams
- feat(example): follow-tail auto-scroll + collapse long thinking blocks
- fix(example): work bar for grid-opened apps; prove permission persistence

## 0.1.69

- fix(example): unblind hosted models — vision detection + settings checkbox
- feat(example): localize the UI (en/ru) with a hardcoded-string guard test
- perf(cli): coalesce streamed output deltas to keep typing responsive
- fix(cli): keep the ctx gauge at the last real usage after a failed run
- fix(example): bump js_widget_runtime to ^0.4.3 — renderer no longer crashes on array borderRadius
- perf(cli): memoize the markdown wrap pass so scrolling stays O(1)
- fix(cli): re-attach follow on submit so the sticky echo pins again

## 0.1.70

- docs: mandate golden tests for all UI work in AGENTS.md
- feat(example): brand fonts (Inter/JetBrainsMono), marketing-grade full-screen goldens, app quality gates
- fix(example): absolute path for upload_picker_web conditional import
- fix(example): update imports for the sandbox/services/ui layout
- feat(cli): name the key source (environment vs secure store) in the 401 hint
- feat(cli): diagnose auth failures with the key source (env vs store shadowing)
- feat(cli): print the session resume command on exit
- test(example): golden tests for every UI widget + pipeline golden gate
- fix(agent): repair orphaned tool calls in the request payload
- feat(cli): replay the full restored transcript with collapsed tool runs

## 0.1.72

- feat(example): orbit work-bar, light theme, secrets UI, open_app + calendar tools, map node demos

## 0.1.75

- feat(example): animation nodes demo (entrance stagger, animatedSwitcher), theme+reply-sheet sources
- feat(example): jsr.theme plumbing (light/dark live), Fa mini reply sheet, map-app golden
- fix(example): chart node API alignment (0.4.7), gridView docs, bar chart demo

## 0.1.76

- feat(example): chrome modes, branding sweep (fah→Fa), textArea+scrolling docs (0.4.8), system-API design doc

## 0.1.77

- feat(example): contacts domain — channel, agent tools, js bridge, demo app
- feat(example): jsr.fa.llm chat (multi-turn) + stream (delta events)
- feat(example): calendar write — channel, agent tools, js bridge, demo editing
- feat(example): back-swipe contract (jsr.onBack), privacy manifests + usage descriptions

## 0.1.78

- feat: Keychain key persistence (iOS/macOS), /models endpoint listing, model marks, site updates
- refactor(example): dedupe cache sections into shared model_cache_section; bump runtime 0.4.11
- feat(example): transcription slot wiring + read_video (frames → vision)
- feat(example): media models config + generate_image/speak/generate_music tools + js bridge
- feat(example): iCloud sync for sessions/apps (iOS; macOS pending signing)
- feat(example): local push notifications — channel, notify tool, js bridge, reminders demo
- feat(example): HomeKit control (iOS) + mic/ASR voice input
- feat(example): HealthKit read (iOS), scene3d dep (0.4.10), Android readiness doc

## 0.1.79

- fix: commit the missing modifications from models-config and media UI (autostash unstaging)
- feat(example): per-run date refresh, media models full-screen editor with /models picker
- fix(example): dead onPressed buttons (runtime 0.4.12), calendar date-labeled lists + ±7d match, mic e2e probes
- fix(example): current date in system prompt, foreground notification banners, contacts openUrl errors
- feat: CLI models-config (models: config + /models set|remove|config) + media models settings UI

## 0.1.82

- fix(example): browser-ish UA for network images (runtime 0.4.13) + url image probes

## 0.1.83

- fix(example): drop the robot icon + Model header from the sidebar
- fix(example): macOS keychain read + dead platform channels
- feat(example): providers-first settings — provider editor page, default chat model flow, provider-based media slots
- feat(example): providers-first settings — provider editor page, default chat model flow, provider-based media slots
- fix(example): contacts list scroll + live search; paged full-list search with phone matching for dedup
- fix(example): composer stop button while streaming; abort drains steer queue into transcript
- chore(example): pin js_widget_runtime ^0.4.13 (image UA fix)
- fix(providers): dedupe overlapping/cumulative reasoning chunks in openai-completions thinking stream

## 0.1.84

- feat(example): preset default-model override + two-step media slot flow

## 0.1.85

- feat(example): render sandbox images in chat — markdown imageBuilder + inline generate_image tiles
- feat(example): expand Fa chat in place inside JS app views
- fix(example): macOS pods — platform 14.0 + regenerated lock (Firebase 12.x)
- fix(example): in-app Fa stays in the bottom sheet on first contact
- chore(deps): update AI integration deps (firebase, flutter_gemma, js_widget_runtime) and sqlite3; migrate sqlite3 dispose -> close

## 0.1.86

- fix(example): regenerate iOS Podfile.lock (Firebase 12.x + media players)
- feat(example): calendar recurrence, alarms, calendars, span, and url
- fix(providers): thinking — dedupe reasoning vs reasoning_details + tail collapse
- feat(example): inline audio/video playback for sandbox media in chat

## 0.1.87

- fix(example): iOS build — HMHomeManagerDelegate members shadow the homeManager global
- feat(example): HomeKit maximum API, empty-homes race fix, shareable debug logs
- feat(example): privacy-first analytics facade (Firebase Analytics)
- fix(example): contacts — system back steps out of detail, transient call hint
- feat(example): rename sessions, arbitrary agent keys, persist approval mode

## 0.1.88

- fix(example): retry deliver on Apple's bursty Connect API 500s
- fix(example): preflight the macOS store version before deliver
- fix(example): tolerate deliver's first-version 'No data' review-detail crash
- fix(example): shrink RU promotional text under App Store's 170-char limit
- ci: store-metadata workflow — App Store content upload on demand
- feat(example): App Store content pipeline — store goldens, metadata, fastlane lanes

## 0.1.89

- fix(deps): revert sqlite3 to ^2.9.4 — 3.x build hooks break dart compile

## 0.1.90

- fix(example): set the App Store copyright field in the deliver lanes

## 0.1.91

- feat(example): model presets wizard in settings
- feat(example): audio/video playback in the file preview
- feat(example): story-driven App Store screenshots with real photos

## 0.1.92

- feat(example): generate_video tool — async /videos job on the videoGeneration slot
- feat: request_secret tool — agent asks the user for missing credentials
- fix(example): theme-aware FaWorkBar — one component with the chat overlay
- fix(example): HomeKit entitlement + longer homes wait + notify probe
- feat(example): resume the day's session at boot instead of stacking empties

## 0.1.93

- fix(cli): empty Enter submits in guided flows; parse models[]/alias /models dialect
- docs: commit identity policy — ai.teammate for contributors

## 0.1.94

- refactor(test): split agent_cli_test.dart into support + provider/model topical files
- fix(cli): spec env names resolve only for the default hosted endpoint
- fix: video download auth on own-origin urls + provider key name dedupe + keychain preflight
- fix(cli): fa update misdetects a native binary in pub-cache as pub-global

## 0.1.95

- fix(example): pin js_widget_runtime to git fix for JSC use-after-free (TestFlight crash)
- refactor(example): share chat message rendering with the in-app Fa overlay + full state goldens
- fix(example): Fa panel is one bottom sheet, never two stacked cards

## 0.1.96

- fix(example): Home + Health apps scroll — root column → listView

## 0.1.97

- docs(example): AGENTS.md notes for the launcher home, chat sheet and shared composer
- feat(example): session chat bottom sheet over the launcher (pager, shared composer)
- feat(example): apps launcher home on narrow layouts (grid, folders, system tiles)
- fix(example): home control disambiguation (room/UUID) + duplicate-bridge-id write routing
- fix(example): preset carousel is full-bleed — cards slide behind the edges

## 0.1.98

- feat(example): session chat sheet v2 — mini bar with input, smooth physics

## 0.1.99

- fix(example): sheet UX — full-bleed, one surface, ghost panel gone

## 0.1.100

- refactor(example): drop unused members left by the sheet v3 rewrite
- feat(example): sheet v3 — ONE panel: round icon ↔ mini bar ↔ full sheet

## 0.1.101

- fix(example): sheet respects the top safe area + light-theme golden

## 0.1.102

- feat(example): iOS-style home grid — icon-unit alignment, live reflow, resizable tiles
- fix(example): drop the border on the floating chat bar/icon — shadow only
- feat(example): tile span sizes + floating mini chat bar, directional sheet swipes
- feat(example): live app tiles on the launcher + chat sheet mini-by-default

## 0.1.103

- feat(example): first-launch onboarding, scene3d wiring + 3D game demo, sheet/tile polish

## 0.1.104

- fix(example): reliable tile drops, full-width grid, widget drag cards

## 0.1.105

- feat(example): icons-per-row setting, tight row gap, pager bounce fix

## 0.1.106

- feat(example): app content respects the bottom safe area + onboarding replay

## 0.1.107

- docs: privacy policy — PRIVACY.md + published site page, onboarding links it

## 0.1.108

- fix(example): TestFlight JSC crash, ownership-aware demo sync, CRAP yellow zone

## 0.1.109

- feat: CRAP green zone (max ≤ 8), app integration tests, tool-dup fix

## 0.1.110

- fix(example): visible run errors, mini last-message strip, iOS-grade drag&drop, weather timeouts

## 0.1.111

- fix(example): TestFlight SIGSEGV root cause — serialized engine lifecycle

## 0.1.112

- feat(example): iOS background execution + Live Activity, key resolution fix, crash-churn guard, mini drag pill

## 0.1.113

- test(example): real-agent E2E on the macOS host + store promo artwork

## 0.1.114

- ci(ios): scope codesign rewrite to Runner, auto-sign the FaLiveActivity extension (bundle-id collision 90685)
- fix(example): steer button interrupts the run, queued steers run after stop, sheet opens at the latest message

## 0.1.116

- fix(example): close action for full-chrome JS apps (map was unclosable), store copyright name

## 0.1.117

- feat(example): launcher home on all layouts (legacy session sidebar removed), App Store shots v2 ('your own apps, built by chat'), golden orphan gate

## 0.1.119

- feat(yoclip): Fa promo video workspace — 19s promo in 3 aspects x en/ru (App Preview + social + YouTube), creative treatment, VO, music bed, frame QA
- test(example): realistic providers in the store_providers frame; pre-commit format gate scopes to package dirs (yoclip/ is a standalone workspace)

## 0.1.120

- feat(fa_ui): present editor/picker pages as constrained dialogs on wide canvases

## 0.1.123

- feat(site): TestFlight public beta link in the hero CTA row

## 0.1.125

- fix(example): pin js_widget_runtime@9498d0c — revert the native-release grace that defeated the lifecycle serialization (tf-6 SIGSEGV); drop the test-only grace config

## 0.1.128

- fix(apps): jscore multi-instance crash override + seed-error surface + map top inset

## 0.1.130

- feat(launcher): 'Restore reference version' tile menu item for demo apps

## 0.1.132

- feat(fa_ui): extract the agent chat into the shared fa_ui package

## 0.1.133

- feat(fa_ui): avatar builder + theme-driven chat surfaces
- feat(fa_ui): host surface tokens + optional app bar in FaChatScreen
- fix(fa_ui): FaChatScreen honors the host FaUiTheme in the chat theme

## 0.1.134

- feat(fa_ui): userBubble/userBubbleBorder tokens in FaUiTheme

## 0.1.135

- feat(fa_ui): providerId through the connect flow

## 0.1.136

- Add fa_llm package extracted from flutter_agent_memory llm layer

## 0.1.137

- chore(deps): bump flutter_gemma to latest official releases
- feat(fa_llm_flutter): add FlutterGemma on-device provider

## 0.1.138

- feat(gemma): enable on-device Gemma provider on macOS
- feat(fa_ui): wire fa_llm/fa_llm_flutter into provider config

## 0.1.139

- docs(gemma): update platform comments for macOS support

## 0.1.140

- feat(settings): show on-device providers in the Providers section
- feat(settings): voice selection for the TTS media slot

## 0.1.141

- fix(macos): bundle LiteRT-LM companion dylibs for flutter_gemma

## 0.1.142

- macOS: no-sandbox release flavor, HealthKit support, privacy entitlements
- Local models heading, Gemma 128k context, context-fit budget fix
- feat(flutter_app): feature-gate WebLLM, expand Gemma context window, filter BYOK picker

## 0.1.143

- feat(macos): privacy prompts, configurable signing, and no-sandbox release for Fa

## 0.1.146

- fix(macos): split Debug entitlements for local flutter run

## 0.1.147

- fix(macos): surface EventKit authorization failures
- feat(macos): allow explicit calendar permission bootstrap

## 0.1.148

- Gate JS apps and skills by platform

## 0.1.149

- feat(apps): Language Tutor rewrite + fitness-trainer device-path probes

## 0.1.152

- fix(providers): voice sample URLs are case-sensitive on the CDN

## 0.1.153

- feat(providers): Google Gemini media provider + MediaModelsSection in fa_ui

## 0.1.157

- fix(oauth): capture OpenRouter web callback via JS object postMessage

## 0.1.162

- fix(app): key field no longer prefills OPENROUTER_API_KEY for non-OpenRouter providers
- fix(oauth): native iOS/macOS OAuth via HTTPS callback + custom scheme redirect
- fix(oauth): iOS web redirect flow with state + verifier

## 0.1.164

- test(cli): avoid real network in /provider custom default URL test
- refactor(self_manage): lower fallbackZipUpdate CRAP and cover zip path
- ci: pin crap4dart to 0.2.1 to match pre-commit ratchet
- fix(installer): fallback to .zip extraction when raw binary not in release

## 0.1.167

- chore: trigger auto-release for CLI binaries + subagents 2.0
- feat(ui): AppsPanel with search/filters/sections for wide-layout right panel
- fix: remove unused test class + imports causing CI analyze warning
- fix(crap): decompose + cover all new methods to pass CRAP ratchet (12.0)

## 0.1.168

- fix(pages): web demo build is optional (dart:ffi from sqlite3 breaks it)
- fix(installer): $zip_asset… unbound variable — brace the var before ellipsis
- feat(ui): 'Add app' tile in Created-by-you section (prototype style)
- feat(ui): system app tiles grid in AppsPanel (Calendar/Files/Notes/Maps/…)
- feat(ui): tool tiles show display names + dropdown arrows (prototype style)
- feat(ui): user profile section in sidebar bottom (matching prototype)
- fix: suppress dead-code warning on new sidebar null check (line 198)
- feat(ui): permission-denied card for tool errors (prototype style)
- fix: pub.dev publish_to removed, Windows zip uses 7z instead of zip
- feat(ui): Customize label in AppsPanel header (matching prototype)
- feat(ui): composer matches prototype — star icon, Ask anything, up-arrow send
- test(goldens): AppsPanel golden coverage — dark + light variants
- feat(ui): session date grouping + 3-dot menu + subtitle timestamps
- feat(ui): workspace header in wide layout + session tile 3-dot menu

## 0.1.169

- fix: fa update now copies version.txt alongside the new binary
- feat(ui): permission cards with working action buttons
- ci: CodeQL workflow — Dart + JS only (no Java/Kotlin, no Gradle in root)
- fix(security): exact hostname match for testflight.apple.com (CodeQL #7)
- fix(ui): settings/files/model picker as popup dialogs on wide screens
- fix: disable Impeller on macOS to prevent resize crash
- fix(installer): copy version.txt next to binary + fix version lookup path
- feat(ui): FaMark sparkle brand icon (no background) + files goldens update
- fix(security): URL sanitization in analytics.js + workflow permissions
- fix(ui): full-height dividers — panels extend to window top on macOS
- fix(ui): address prototype feedback — tabs, calendar, timer, model switch
- Create SECURITY.md for security policy

## 0.1.171

- chore: trigger CI + auto-release for v0.1.171
- fix(ci): quote sed command to fix YAML syntax
- fix(ci): keep publish_to: none for analyzer; strip it only in the publish job
- fix(installer): rm -f target before cp — break symlinks so version.txt lives next to the binary

## 0.1.172

- fix(version): use Platform.resolvedExecutable so version works regardless of invocation path

## fa_llm-v0.1.1

- feat: switch to hosted flutter_agent_memory dep, remove publish_to: none

## 0.1.173

- fix(ci): restrict auto-release tag matching to v*.*.*; fix pubspec version
- feat(ui): auto-focus composer input on session open/switch
- fix(testflight): fail on submit errors; fix framework bundle IDs; cleanup publish job
- feat: switch to hosted flutter_agent_memory dep, remove publish_to: none
- chore: add LICENSE to fa_llm for pub.dev
- feat: prepare fa_llm for pub.dev publishing

## 0.1.175


- feat(providers): DIAL provider kind — `{baseUrl}/openai/deployments/{model}/chat/completions` with `Api-Key` auth, optional `DIAL_API_VERSION` query, `/openai/models` listing; `--provider dial --model <deployment>` headless

## 0.1.176

- fix(analyze): await in try block, drop unused imports
- test(crap): decompose + cover new subagents/a2a/memory methods (CRAP ≤ 12)
- feat(ui): brand icon in dark + light forms, styleguide colors in onboarding
- chore: drop unused imports
- fix(providers): commit the FA_PROVIDERS filter + enabledProviders definitions unbreaking main
- style: dart format task_executor
- docs(subagents): mark all phases done + AGENTS.md bullets for memory/a2a
- test(subagents): real-model test skips without ZAI key, longer timeout
- feat(a2a): phase 5b — fah serve --a2a HTTP mount + full client↔server loop verified live
- feat(ui): onboarding top padding, privacy link, centered wide layout + light macOS icon
- feat(a2a): phase 5a — a2a: config, A2aManager lazy connect, task tool a2a:<name> remote agents, /a2a status
- feat(memory): phase 2 — compaction extraction hook, maintain() pipeline, /memory command
- feat(ui): onboarding redesigned pixel-close to the reference prototype
- feat(subagents): reply tool, agent_message sibling messaging, completed_without_reply notice + pending-queue guards
- fix(ci): remove stray file "flutter_app/\" breaking the windows checkout
- feat(ui): Focus Timer as standalone dark card with circular progress ring
- feat(ui): onboarding rewritten to match reference — 3-col mockups, circular Focus Timer, colorful icons

## 0.1.177

- feat(ui): onboarding provider step is real and mandatory
- test(crap): decompose + cover /agents panel methods (pure helpers in agent_tree.dart), public subagentManager getter
- fix(analyze): drop redundant null guard in agents section
- feat(app): agents panel in settings — live subagent tree with observe/send (CLI parity)
- test(cli): /agents tree panel integration test (keyless)
- feat(cli): agents viz A+B — live agents badge in status line, /agents tree panel with observe/send
- fix(ui): saturated glyph colors for the light brand icon
- feat(task): Claude Code agent compat — .claude/agents roots + model: frontmatter alias
- fix(ui): macOS traffic-light clearance for pushed AppBar routes
- fix(ui): pin the onboarding Privacy link to the footer center
- feat(ui): single brand tile everywhere, glyph rebalanced in the icon
- fix(analyze): drop unnecessary non-null assertion
- feat(task): subagent model role — settings-picked delegation model (TaskModelsStore + roles: config), smol/explore precedence

## 0.1.178

- feat(app): live agents badge in FaWorkBar (CLI bg: parity) + fix cli_visual tests for new settings hub order and /agents tree

## 0.1.179

- fix(crap): simplify pickAgentAction dispatch; broaden badge visual soft-skip catch
- chore: drop unused session_repo imports
- feat(cli): extract active-agents badge to pure helper + unit tests; soft-skip live badge visual test
- fix(tui): soft-wrap long input lines instead of horizontal clipping
- feat(subagents): real JSONL child sessions at completion + /agents open <id> (race-free register)
- feat(providers): list-first model pickers everywhere — quick search, manual escape, agent models flow
- feat(cli): /agents child → Open session action — switch into the subagent's session

## 0.1.180

- feat(memory): keyword-only search fallback without an LLM provider
- fix(subagents): fire-and-forget registry persistence + per-session rehydrate
- fix(providers): connect + idle watchdogs on provider streams
- feat(ui): brand provider icons in onboarding, file split, iOS icon sync
- feat(session): never keep an untouched session file
- chore: drop unused import
- fix(cli): provider wizard asks for the key in roles mode; switches accept it
- feat(subagents): crash-resilient child sessions — spawn-time async creation + incremental turn flush (serialized, fire-and-forget)
- fix(memory): inject the <memory> section into the system prompt (CLI + app)
- test(cli): drop flaky real-model live badge visual test (unit-covered badge logic); document why

## 0.1.182

- test(messaging): drop unused import (dart analyze warning)

## 0.1.185

- feat(tui): leave the mouse to the terminal by default (FA_TUI_MOUSE=1 to capture)
- fix(app): iOS CodeMie SSO — run the real loopback callback server

## 0.1.186

- fix(crap): decompose FaTuiModel._submit/_wrappedInput (CRAP 12.14/12.01 -> in budget)
- refactor(cli): split provider key helpers out of provider_commands.dart (2800-line gate)
- fix(providers): roles-mode switches preserve the scoped key; messaging presence
- test(cli): visual integration coverage for the new TUI UX
- feat(tui): shell-style input history on ↑/↓
- feat(messaging): live cross-instance chat — discovery, self-address, idle wake
- test(app): web-safety guard — no Platform.is without a kIsWeb guard
- test(messaging): visual integration for the agents inbox + terminal-safe marker
- fix(app): no crash on CodeMie/ChatGPT taps in the web build

## 0.1.187

- refactor(ui): sane Settings structure — providers include on-device, one Models group

## 0.1.188


- feat(app): js_widget_runtime back on hosted pub (`^0.4.79`, the git pin
  dropped) — JS apps gain the Material 3 catalog: appBar/navigationBar/
  navigationRail/tabBar/fab/segmentedButton/radio/searchBar/tooltip/
  popupMenu/banner/bottomAppBar/carousel/drawer, modal overlay nodes
  (bottomSheet/dialog/snackBar/datePicker/timePicker), `flChart`
  (line/bar/pie/radar/scatter via fl_chart), new layout/display/input nodes
  (wrap/align/flexible/spacer/scroll/clipRRect/svg/markdown/chip/badge/
  progress indicators/switch/checkbox/slider/dropdown, textButton/
  outlinedButton/iconButton), M3 motion tokens — and the seeded `js-apps`
  skill documents the whole catalog
- fix(providers): one shared keep-alive HTTP client for all provider streams
  instead of a fresh client per call — per-turn TCP churn piled up TIME_WAIT
  sockets until connect() stalled into the watchdog (`TimeoutException:
  Future not completed`); kimi-cli/pi reuse one client for exactly this
  reason. Aborts still close just their own response subscription
- fix(compaction): auto-compaction no longer spins identical no-op passes to
  the max after a compaction: a pass with nothing left to cut stops the loop,
  and the post-pass transcript restamp clears the kept messages' stale
  generation-time usage so the estimate reflects the compacted size (before,
  a compacted session kept reporting its pre-compaction ~200k and retriggered
  compaction on every idle wake)
- fix(tui): the status row is padded to the terminal width — switching from
  a long model id to a shorter one no longer leaves the old tail on screen
- fix(cli): the status line is live again — ctx% shows the current context
  pressure (provider-reported usage plus the estimated tail, i.e. what the
  next request carries, not the last turn's frozen prompt size) and the tok
  counter grows during streaming (settled turns + in-flight estimate)
- fix(providers): inline `<think>…</think>` tags in the content stream (kimi
  k3 via openai-completions and other endpoints without a reasoning field)
  are extracted into the thinking block instead of rendering as raw tags —
  streaming-safe (tags may split across deltas)
- fix(tui): history wrapping no longer breaks markdown styling — the wrap is
  now word-aware (no more mid-word cuts) and active SGR styles are closed at
  the cut and re-opened on the continuation row, so a wrapped bold/code span
  keeps its style instead of going plain (visible mostly after resizes)
- fix(tui): restored sessions no longer lose markdown formatting after an
  unclosed code fence — replay truncation (20-row cap) and the replay budget
  cut could leave the fence state dangling, rendering everything after as
  verbatim text; truncated messages now close their fence synthetically and
  a budget cut starting mid-fence prepends a balancing opener
- fix(tui): restored sessions no longer dump the raw `<summary>`/`<read-files>`
  block into the history — a projected compaction/branch summary replays as
  one dim marker row with the summary's first line as a hint
- feat(config): provider watchdogs are configurable — `providerTimeouts:`
  section in `~/.fah/config.yaml` (`connectTimeoutMs`, `streamIdleTimeoutMs`;
  strict parsing) for slow endpoints whose first byte takes minutes; the
  connect default itself is raised 60s → 180s (loaded reasoning endpoints
  hold big requests before the first byte) and the stream-idle default
  120s → 5min (reasoning models think for minutes between chunks — pi and
  kimi-cli carry no such watchdog at all / SDK's 600s total)
- fix(tui): Cyrillic/CJK paste no longer arrives as mojibake — dart_tui
  2.0.0's bracketed-paste decoder maps every pasted byte to a Latin-1 char
  code; fa re-decodes the (lossless) mis-decoded text as UTF-8 at the
  PasteMsg boundary
- fix(tui): Ctrl+S no longer freezes the terminal — dart_tui's raw mode left
  termios IXON on, so Ctrl+S was the tty driver's VSTOP (XOFF: output froze,
  the keypress never reached the app); the TUI now disables software flow
  control for its lifetime and restores the saved termios on exit
- feat(tools): background shell jobs — `bash background: true` runs detached
  (log in `.fah/bash_jobs/<id>.log`), `bash_job {status|output|stop}` manages
  them, completions re-enter the conversation as system-notices (steered
  mid-run, fresh turn while idle)
- feat(agent): steer soft-yield — a message arriving mid tool-call phase
  (Ctrl+S, subagent completion, inbox mail) asks yield-aware tools to finish
  the call early WITHOUT stopping the work: a running foreground `bash` moves
  to a background job untouched, a blocking `task` converts still-running
  children to background jobs; the user message is delivered at the next
  step boundary instead of after the whole tool call
- feat(task): model-facing `task_cancel` aborts a running background subagent
  job; `/tasks` lists background agents AND shell jobs, `/tasks cancel <id>`
  routes by id
- feat(app): background shell jobs on every platform — the desktop app
  forwards the host shell's capability through `ProjectMountEnv`; mobile's
  `WasiSandboxShell` and web's `MemoryShell` run jobs as detached script
  Futures on job-local interpreter clones (own cwd/vars/output capture,
  shared filesystem), so `bash background: true` + steer-yield work in the
  sandbox too

## 0.1.191

- feat(cli): add auth-method picker for CodeMie SSO/JWT and OpenRouter OAuth/key
- feat(cli): auto-restart CodeMie SSO when the saved cookie expired
- fix(cli): catch uncaught errors and harden provider switch against crashes
- fix(ui): make ChatComposer transparent and regenerate goldens
- fix(network): use platform HTTP client for sandbox env, allow local HTTP, log bookmark failures
- fix(macos): add app-scope bookmark entitlement and surface folder picker errors

## 0.1.194

- fix(ci): merge Release.entitlements into the signed macOS build, don't strip them

## 0.1.195

- fix(install): macOS CLI bundle + quarantine/sign handling

## 0.1.199

- fix(cli): show auth-method picker when adding openrouter/codemie from TUI

## 0.1.200

- fix(ios): correct force_load path — pod products live in a per-pod subdir
- fix(ios): force-load cupertino_http pod binary + CI gate on its FFI symbols
- fix(flutter_app): project mount sets agent cwd to /project so sessions are folder-scoped

## 0.1.202

- fix(install): remove broken Dart fallback, respect FA_INSTALL_DIR, sign macOS CLI in CI

## 0.1.203

- fix(cli): provider picker, CodeMie auth refresh, skills access
- feat(session): unify CLI and macOS app session storage
- fix(providers): restore Kimi endpoint (api.kimi.com/coding/v1) and default model k3
- fix(cli): auto-refresh expired CodeMie SSO cookie on startup

## 0.1.204

- fix(providers): do not close shared HTTP client during OpenRouter OAuth exchange

## 0.1.206

- fix(app): skill discovery scans user-level roots (~/.claude, ~/.copilot, ...)
- ci(macos): tolerate an existing keychain when packaging the TestFlight PKG

## 0.1.207

- fix(app): explain empty responses that follow an image-bearing prompt

## 0.1.208

- feat(attach): live CLI sessions in the app — presence, 1:1 view, input handover

## Unreleased
