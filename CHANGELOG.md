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

## Unreleased
