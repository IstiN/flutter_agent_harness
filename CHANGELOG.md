# Changelog

## Unreleased

- feat(js-ext): JS extension core (issue #32) — `JsrRuntime` engine seam +
  engine-agnostic bootstrap (`jsr.ext.*`: registerTool tiers, six hook
  events, slash commands, provider flows, session/fs/exec/keys/io/has
  bridges) over three transports (qjs stdio, flutter_js send-message, web
  worker); `JsExtensionHost` wires commits into the agent with
  deny-precedence hook composition (JS can only tighten), append-only
  `afterToolCall` redacted twice (before JS sees it, before persist),
  read-only `prepareNextTurn`, E14 follow-up collapse, and 30/10/120 s
  load/hook/tool budgets that degrade to log lines, never crash the loop;
  manifest/trust/install machinery — strict accumulating manifest parse
  (E12), TOFU trust with capability-diff re-prompt + hash-only silent
  re-grant, local/zip/gh/catalog/bundled planners with sha256-verified
  hostile-zip rules, and the tolerant v2 catalog client (unions `widgets`
  + `extensions`).
- feat(cli-ext): `fa ext list|install|remove|update|audit` with
  `--pin <sha256>`/`--trust`/`--strict`/`--bundled`/`--json` (enable/
  disable stay REPL-only), the quickjs-ng engine process (`qjs --std`,
  binary via explicit override → `FA_QJS_BIN` → PATH, missing binary
  degrades to an `engine unavailable` skip), the `/ext` REPL family
  (list/enable/disable/audit/remove/update/reload), and idempotent
  `.fah/bootstrap.yaml` applies at every start — project then user, E16
  project-wins shadowing, E15 named soft-fail lines unless
  `FA_EXT_BOOTSTRAP_STRICT=1`.
- feat(app-ext): `flutter_app/lib/services/ext/` — `AppExtensionService`
  owns the on-device store roots + host; flutter_js (native) and web
  worker (web) runtimes behind one factory. v1 scope: trusted-only load
  (no trust prompt — untrusted extensions tombstone-skip); the app trust
  UI lands in a later wave.
- feat(js-ext): bundled `crap-guard` reference extension (post-edit CRAP +
  2800-line guard via `crap4dart`, 2 s edit debounce, one aggregated
  `{append}` per burst, E17 single missing-tool note) compiled in as const
  strings, byte-mirrored into `js-ext-registry/crap-guard/` for publishing
  (sync test enforces equality) with a README covering the fa_widgets
  `catalog.json` entry, zip + `shasum -a 256` recipe, and gh-repo layout;
  authoring guide in docs/js-extensions.md.

- feat(browser-ext): browser extension v2.1 (issue #30) — fa web moves
  into the extension and grows browser superpowers. The panel is now an
  app-hosting bootstrap: `scripts/build_browser_ext.sh --with-app`
  bundles the Flutter web build as `browser_ext/app/` and the side
  panel/full tab loads it (v1 minimal chat stays as fallback). The
  service worker gains the UI protocol server — `FaUiProtocol` over a
  `chrome.runtime` port (17 message kinds: hello/attach/prompt/steer/
  cancel/stream/approval/sessions/settings, prompt-id dedup + attach
  replay), `WorkerRelayTransport` vs `LocalStreamTransport` with
  capability detection — and a 34-tool browser surface
  (`browser_api_tools.dart`) over the typed `ChromeApi` facade (23
  chrome.* groups): tabs/windows/groups/sessions/history/bookmarks/
  downloads/cookies CRUD, first-class `inject_js` (ISOLATED/MAIN worlds,
  MAIN always prompts) + `inject_css`, `cdp_eval`, `page_screenshot`,
  `app_screenshot`, `nav_wait`; restricted pages refuse scripting.
  Permission⇄tool matrix (`permission_matrix.dart`): 28 core rows /
  9 second-tier optional / 11 excluded (incl. the impossible-by-
  construction `passwords` row), unpacked vs store manifest profiles
  (store strips `debugger`+`cookies`); manifest 0.2.0 with 26 core
  permissions, second tier in optional_permissions, `ask-fa` command
  (Ctrl+Shift+1) and omnibox keyword `fa`. Background residency: badge
  state machine (idle/busy/mail, resync after SW kill, denied-
  notification fallback), exactly-once scheduled tasks over
  `chrome.alarms`, lifetime-capped offscreen documents, EntryPointHub
  steering omnibox/commands/contextMenus into one agent. Security layer:
  quarantine + instruction-hierarchy classifier (page bytes are always
  data), injection validator (login-form/keylogger refusals), exfil
  gate (page-derived/cross-origin/data-exit approval), and a new
  `layer_credential.dart` redaction layer masking credential-shaped
  form values pre-persist. Docs rewritten:
  browser_ext/README.md, docs/browser-extension.md, new
  docs/browser-extension-permissions.md. Pending: flutter_app
  worker-relay chat integration, Playwright e2e, store publication.

## 0.1.297

- fix(tui): a long thinking burst froze the whole TUI (typing dead, spinner
  stuck — user report: "пиздец как тормозит" on a glm-5.3 session). Root
  cause: the CLI wrapped every thinking delta in inline markdown, and the
  escape-dense result drove AnsiMarkdown's inline link regex into
  quadratic backtracking — measured 10.9 s of synchronous work per
  coalesced 185 KB flush. Two fixes: thinking deltas now dim verbatim
  (spans cannot pair across deltas anyway), and inline span substitution
  is skipped for lines over 4 KB (`AnsiMarkdown.inlineFormatMaxChars`) —
  degenerate spans render verbatim, fences/rules/tables unchanged.
  Regression-tested by the new `tool/thinking_lag_probe.dart` PTY probe
  (burst streams: keypress echo p95 stays under budget) and a markdown
  unit test.
- docs(readme): reflect the shipped surface — status, design contract,
  what's inside (agent core, providers, sessions, tools, skills,
  approval gate, trajectory, messaging), CLI slash commands.

## 0.1.296

- feat(bash): automatic transient-failure retry — timeout-class failures
  (the model's per-call cap, or an outer future cap on a hung transport,
  e.g. a stalled `gh` API call) are retried up to 2 times (3 attempts
  total) with a 1s backoff before the error surfaces. Retries are visible
  as `[bash attempt N/3 ... — retrying]` notices in the tool output, and
  the final error carries them too. Aborts and real command failures
  (non-zero exit, exec errors, shell unavailable) are never retried.
- fix(app): the macOS/iOS app could boot to a black screen — the native
  Firebase SDK auto-configures the [DEFAULT] app from
  GoogleService-Info.plist at plugin registration, so the Dart
  `Firebase.initializeApp` threw an unhandled [core/duplicate-app] that
  killed main() before the first frame. The duplicate-app case now reuses
  the natively configured app.

## 0.1.296

- feat(bash): automatic transient-failure retry — timeout-class failures
  (the model's per-call cap, or an outer future cap on a hung transport,
  e.g. a stalled `gh` API call) are retried up to 2 times (3 attempts
  total) with a 1s backoff before the error surfaces. Retries are visible
  as `[bash attempt N/3 ... — retrying]` notices in the tool output, and
  the final error carries them too. Aborts and real command failures
  (non-zero exit, exec errors, shell unavailable) are never retried.

## 0.1.295

- docs: fa1.dev is now referenced from the README (website + live web
  demo + iOS beta + installer) and from `homepage` in pubspec.yaml, so
  the link renders on pub.dev next to the package name.

## 0.1.294

- feat(redact): layered secret redaction pipeline (issue #24) — ten pure
  layers (registered/path/vendor/prefix/pem/asn1/connection/context/
  entropy/pii) merged priority-first into `RedactionPipeline.scan/redact`
  with idempotent `[REDACTED:<kind>]` markers, allowlist + data-URL
  pass-through, live `RedactionConfig`, and per-layer/per-tool stats.
  Agent hooks mask tool results BEFORE session persist, mask the outgoing
  context, deny credential-file read/bash in `blockMode`, and mask user
  prompts; write-side tools (write/edit/checkpoint/MCP write-ish) are
  never filtered. `redact:` config section, `/redact` command, app wiring,
  docs/redaction.md.
- test: tui_prototype_snapshot marked `integration` — the real-PTY +
  `dart run` cold start intermittently exceeded the gate timeouts on CI,
  which had been silently blocking every tag publish since ~0.1.214.

## 0.1.289

- fix(roles): transient transport failures no longer kill the turn. A
  dropped connection ("Connection closed while receiving data", resets,
  refusals, DNS/TLS handshake failures, 502/503/504) during a provider
  call is now retried in place with the retry policy's backoff budget
  (`retry.retriesPerEntry`, default 2), then falls over to the next chain
  entry — the run survives instead of ending with an error event. Key
  rotation is deliberately skipped for this class (the endpoint dropped,
  not the credential), the observable-output guard still holds (a stream
  that already emitted content is never silently replayed), and every
  retry is announced via `FallbackNoticeKind.transportRetry` (the CLI
  prints `[roles] connection lost on … — retrying in Ns`).
- fix(app): the onboarding flow follows the dark theme — provider cards
  were hardcoded `Colors.white` with near-white title text (white on
  white), the wide ghost column's "Ask when needed" used the brand blue
  on a near-black background, and step dots/progress tracks/dividers were
  light-themed; all now route through the `_onb*` dark-aware helpers with
  a readable `_onbPrimary` accent in dark mode.
- fix(cli): steering robustness — file-path-prefixed input sent while a
  run is busy is steered with its attachment instead of dying on the busy
  gate, steered `~/`/`./` paths resolve like interactive input, leftover
  steering after an aborted/interrupted run runs as a fresh turn or is
  dropped loudly (texts printed), and queue drops always show what fell
  out instead of vanishing silently.
- fix(cli): a `!command` executed locally now also steers a compact
  `<system-notice>` (command + exit code + capped output tail) into the
  conversation — the agent learns what ran without being woken.
- deps: the DAP hub client moved to the published `fa_hub_client` 0.2.8,
  whose reconnect backoff no longer overflows after ~64 attempts (Dart
  int shift semantics: `1 << 64` == 0) into a zero-delay tight reconnect
  loop against a dead hub — the root cause of the multi-hour CPU storms.
- fix(tools): media slot overrides no longer fall back to the main
  provider API key — a slot override is its own provider configuration
  (CLI `generate_image` + the app's `MediaModelsStore.resolve`).
- fix(tools): `generate_image` surfaces MiniMax `base_resp` errors that
  hide inside HTTP 200 responses.
- fix(cli): per-folder model memory — `/model` and `/provider` switches
  are scoped to the launch folder; the global config keeps its seed
  triple, so a switch in one workspace no longer leaks into the others
  across restarts.
- fix(cli): model/provider persistence callbacks are awaited — `/model x`
  + `/exit` can no longer lose the switch.
- fix(cli): the over-window context guard renders a calm yellow note
  instead of a red error; explicit guidance when compaction cannot free
  the window.

## 0.1.282


- feat(cli): a `DAP / Hub` entry in the `/settings` hub — view the live
  hub snapshot (resolved url, agent name, connection state), set the hub
  url and the agent name (persisted through the hub client's
  `~/.dap/config.json` read-modify-write, so channels and invites
  survive), test the connection, and write the `hub: false` plugin
  opt-out into `.fah/packages.yaml` (existing sections preserved). The
  flow reads the hub state through an injectable snapshot seam the
  executable wires to the hub plugin — no sockets, fully fake-drivable
  in tests.
- fix(cli): `.fah/packages.yaml` entries actually load now — package:yaml
  reifies its map entries as dynamic-keyed, so the loader's String-keyed
  `whereType` filter dropped every entry and the whole file (plugin
  enabling and configuration, `hub:` url/name, `hub: false` opt-outs)
  was inert. The loader now deep-converts the parsed yaml tree to plain
  Dart values before handing sections to plugins and the DAP / Hub
  settings flow.
  The loader now lives in `lib/src/plugins/packages_config.dart` (reading
  through the ExecutionEnv), so tests can pin it without importing the
  executable.
- feat(app): DAP/Hub settings section in the Flutter app — a settings row
  opening the hub page (resolved URL, connection probe, agent name/agentId,
  channels) with add/edit of the machine-shared `~/.dap/config.json`
  connection via `fah_hub_client`; web degrades to an honest
  not-supported note (the hub client is IO-bound).
- fix(dap): a `dap_dm` to a known-but-offline peer no longer reads like
  a typo — the no-match error lists the known online peers and points at
  `dap_invite` for offline peers and `dap_peers` for typos.
- feat(plugins): `FahPlugin.dispose` — the CLI calls it once per plugin
  at shutdown (errors swallowed per plugin, so one bad plugin cannot
  block exit); plugins override it to release sockets, processes, and
  timers. The hub plugin host disposes the vendored hub client.
- chore(cli): the `fah_hub_client` import in `bin/fah.dart` is now
  marked as the ONLY core-CLI import of the hub client — downstream
  forks wanting a different or no hub client patch that import plus the
  `'hub'` case in `_builtInPlugin`.

- fix(messaging): `agent_directory` no longer drowns in graveyard mailboxes —
  it lists LIVE mailboxes (recent activity) plus anything holding pending
  mail and the agent's own address; stale mailboxes from long-finished
  sessions appear only with the new `all: true` parameter. Liveness is
  source-defined `MailboxEntry.lastActivity` (`MailboxEntry.isLive`,
  15-minute default window): the file repository scans the `.heartbeat`
  marker plus `inbox`/`read` content mtimes (the `.id` identity marker and
  `_scheduled`/dot directories are excluded), and running hosts keep the
  heartbeat fresh from their existing inbox-watch timers via the new
  `MessagingRepository.touch` (CLI every ~4s, app every ~6s; best-effort).
  Unknown-activity entries (custom repositories) are never hidden.

- refactor(cli): the `fah` executable's startup is decomposed — the pure
  phases (`serve --a2a` argument interception, provider/model restoration,
  the secure-store preload set, the startup API-key decision, roles-secret
  collection, secret-redactor and web-search assembly) moved to
  `lib/src/cli/startup.dart` with unit tests in `test/cli/startup_test.dart`;
  `bin/fah.dart` keeps only process glue and `_runApp` reads as a phase
  sequence. The CRAP ratchet is green again (worst 12.00): the
  plugin-resolution test importing `bin/fah.dart` had dragged the whole
  executable into the coverage trace at 0% hits, scoring `_runApp`
  CRAP 3906.
- fix(dap): vendored hub client warns loudly when the identity file's
  `chmod 600` cannot be applied (no `chmod` on Windows, or the call
  fails) — the Ed25519/X25519 private seeds would otherwise persist with
  default permissive ACLs, readable by other local users.
- fix(dap): vendored hub client's HKDF expand enforces the RFC 5869
  255-block cap (throws `StateError`) — a zero-length MAC from a
  misbehaving crypto dependency can no longer hang the hub connection.
- fix(dap): `.fah/packages.yaml` plugin opt-out is value-aware —
  `hub: false` (or an empty value) now really disables the plugin
  instead of the key-only de-dup keeping it on; a failing connect to the
  zero-config default hub prints one quiet hint line instead of a raw
  error, so plain CLI starts stay clean.
- fix(dap): the hub plugin's fire-and-forget connect carries a defensive
  `.catchError`, so a future escape can never kill startup silently.
- feat(memory): the long-term-memory LLM slot is wired — a new
  `HarnessLlmProvider` adapts fa_llm's `LlmProvider` onto the harness
  streaming contract and is resolved per call (`memory` role → `smol` →
  main) in BOTH the CLI and the app. Memory consolidation and semantic
  search now actually run instead of being silently skipped.

## 0.1.280

- fix(providers): correct the Copilot token guidance (0.1.278 had it
  backwards). Per the official GitHub Copilot CLI docs (2026-09), the
  supported credential types are fine-grained PATs (github_pat_…,
  v2) WITH the "Copilot Requests" permission and OAuth tokens — while
  classic PATs (ghp_…) are NOT supported by Copilot at all. 0.1.278
  rejected all github_pat_ tokens up front and recommended ghp_ —
  blocking working tokens and pointing at dead ones. Now: a pasted
  fine-grained PAT is accepted with a hint that the "Copilot Requests"
  permission is required (its absence is what makes the exchange 404),
  a pasted classic ghp_ token is warned about and re-asked, and the
  exchange 404 message names the missing permission.

## 0.1.278

- fix(providers): GitHub Copilot rejects fine-grained PATs clearly, at
  connect time. The Copilot token exchange answers `github_pat_…` tokens
  with HTTP 404 (GitHub's Copilot credential API only accepts classic
  PATs and OAuth tokens), which used to surface as a bare "token exchange
  failed (HTTP 404)" on the first message and, during connect, as a
  silent fall-back to manual model entry (the `/user` lookup accepts
  fine-grained PATs, masking the problem). Now: the paste-token step
  rejects a fine-grained PAT immediately with the fix (use the GitHub
  device flow or a classic `ghp_…` token), the exchange short-circuits
  the known-dead token type without a round-trip, the 404 names both
  likely causes (token type / no Copilot plan), and a failing exchange is
  reported during connect instead of an unexplained empty model list.
- chore(cli): split the banner/key-status block out of `agent_cli.dart`
  and disentangle `_runPrompt` (error-stop and empty-continue branches
  into named helpers) — the file-size guard and the CRAP ratchet are
  green again.
## 0.1.277

- fix(cli): endpoint-reported context windows now apply in roles mode.
  The Copilot `/models` limits (`capabilities.limits.
  max_context_window_tokens` / `max_output_tokens`) were parsed and
  applied only when no `roles:` resolver was configured; with one, a
  chain entry riding the catalog default silently kept the provider's
  default window — the copilot default is 1M, so a 256k model (live-
  verified: the endpoint reports kimi-k2.7-code = 256000/32000) ran
  with compaction thresholds sized for 1M and the over-window guard
  never fired in time. Roles entries with EXPLICIT `contextWindow`/
  `maxTokens` still win over the endpoint (per-limit).
- fix(cli): the line REPL warms the model cache like the TUI, so
  `/model <id>` switches see endpoint limits there too.

## 0.1.276

- fix(cli): the over-window guard no longer strands the agent mid-task.
  When the guard stops a run (outgoing context past the model window),
  the post-run auto-compaction frees the window and the CLI CONTINUES
  the interrupted turn on its own — once per user prompt, delivering a
  `<system-notice>` that names what happened and tells the model to
  avoid re-reading the outputs that filled the window. Ending the run
  there left live sessions idle until a manual "continue" (seen on a
  glm-5.3-flash session: guard at 200676/200k, local trim to 20k, then
  silence). `_maybeAutoCompact` now reports whether it actually shrank
  the transcript; the continuation fires only when the window was
  really freed.
- fix(cli): compaction settings scale with the model window
  (`CompactionSettings.forWindow`) unless `compactionSettings:` is
  pinned in the config — matching the Flutter app's existing rule. The
  pi-fixed defaults (keep 20000) structurally prevented compaction on
  small-window models: with keep 20000 on an 8k window the kept region
  always covers the whole transcript, so nothing could ever be
  summarized away and the over-window guard could never be satisfied.
- app: the same guard + compact + continue flow in `AgentService` (once
  per user text, reset on the next real input).
- agent_loop: exported `contextWindowExhaustedMarker` and
  `isContextWindowExhaustedError` so hosts recognize the guard without
  parsing numbers out of the error text.
## 0.1.274

- fix(compaction): the summarizer can no longer hold the turn hostage.
  A dead/dribbling summarizer endpoint used to keep the "Compacting
  context…" row up for up to ~20 minutes (10-minute per-attempt budget
  from 0.1.240, smol + main): the per-attempt budget is now 90 s and a
  new whole-run `totalBudget` (4 min) skips any further attempts once
  burned, falling to the mechanical local trim. New
  `AutoCompactorHooks.onAttemptStart` surfaces each attempt in the busy
  row ("smol=provider/model, attempt 1, 90s cap") so the wait reads as
  bounded, and the CLI resets its delta tail per attempt.
- fix(agent-loop): mid-turn over-window guard — before each provider
  request the outgoing context is estimated; past the model's window
  the run stops with a clear "Context window exhausted" error instead
  of silently sending a 287k-token context to a 200k model (seen live:
  compaction only runs at turn boundaries, and a single verification
  turn with full-suite logs ballooned far past it). Gross overflow
  only — between the compaction trigger and the window the post-run
  compaction flow still owns the decision.

## 0.1.273

- fix(agent): `Agent.abort()` disarms the run idle watchdog — it guards a
  WEDGED stream going silent, not a host that cancelled on purpose; an
  8-minute timer no longer outlives an aborted run. The app's
  `AgentService.dispose` now aborts an in-flight run (its error callback
  skips `notifyListeners` once disposed), which un-wedged the widget-test
  floor: 8 pre-existing flutter_app failures from the 0.1.271 watchdog
  (chat screen, session binding, work bar, session chat sheet) pass again.
- refactor(tui): split `_handleBusyMsg`'s transition diagnostic/copy out
  of the dispatcher (CRAP 15.15 → under the pinned 12.0 ratchet).

## 0.1.272

- fix(providers): no provider carries a default model anymore — every
  connect/switch flow picks the model explicitly. `/provider kimi` and
  `/provider copilot` now fetch the endpoint's /models (the Copilot
  dialect runs the GitHub→Copilot token exchange first) and ask the user
  to pick, falling back to a manual id entry when the fetch is empty; the
  silent `gpt-4.1` seed is gone from the Copilot connect flow.
- fix(providers): the Copilot /models dialect lists only picker-eligible
  chat models — pi-mono parity (`model_picker_enabled`, `policy.state`,
  `supports.tool_calls`) plus a `supported_endpoints` check: responses-only
  models (e.g. `gpt-5.6-sol`) 400 with "not accessible via the
  /chat/completions endpoint" on our chat transport and are no longer
  offered.
- feat(cli): `/model` and `/provider` switches print a role-models note
  naming the models the smol/subagent/memory roles still run, so a
  main-model switch never silently strands a mismatched combination
  ("/settings → Agent models to adjust").
## 0.1.271

- fix(tui): the busy row now names its owner and dies on its own. Every
  arm/release carries a provenance tag rendered in the row
  (`Working… 91s · run`) and logged to fa.log; a stretch silent for 3+
  minutes shows a `quiet Nm` hint instead of pretending steady progress;
  and a model-level watchdog force-releases any row with zero activity
  for 10 minutes — the last-resort finally for the immortal "Working…"
  class, with the last armer named in the diagnostic log.
- test(tui): provenance render, transition forensics, quiet hint, and
  the watchdog release are all pinned in fa_tui_test.

## 0.1.270

- fix(memory): flutter_agent_memory 0.2.1 — the deletion ledger is now
  strictly append-only (a delete never rewrites existing content;
  tolerant parser infers a missing `type:` from the id prefix and
  recomputes missing fingerprints), closing the clobber class that
  erased 144 tombstones in production. `ExecutionEnvKbStorage`
  implements the new `KbAppendCapable` through the existing
  `ExecutionEnv.appendFile` — racing deletes append instead of
  read-modify-write last-writer-wins.
- test(memory): regression pins the incident: a legacy 144-entry
  ledger with the `count:` header survives a delete with every
  tombstone intact and the new entry appended; the adapter's native
  append is asserted directly.

## 0.1.268

- fix(tui): the "Working… Ns" immortal-spinner wedge (found live: a
  session burned 100% CPU for 8 hours after the run had cleanly ended —
  `Working… 28301s`). Root cause in the TUI busy state machine: a raw
  `BusyMsg(true)` landing on an IDLE model — a post-run straggler like a
  compaction finally-branch calling `setBusyPhase('')` after the busy
  bracket released — re-armed the spinner with a fresh elapsed window and
  scheduled a NEW 100ms tick chain; nothing ever sent the matching
  `BusyMsg(false)`, and every chain re-rendered the full transcript
  (268k tokens) ten times a second — the 99.8% CPU storm. Two guards now
  close the class: the model drops phase-relabels and duplicate busy
  starts while idle/already-busy (no new window, no extra chain — one
  chain per busy stretch), and the controller's `setBusyPhase` no-ops at
  busy-depth zero. Regression tests: post-run straggler cannot resurrect
  the row, duplicate starts keep the single chain.

## 0.1.267

- feat(memory): flutter_agent_memory 0.2.0 — merge-friendly note ids
  (`n_0447_a1b2` = sequential index + 4-hex md5 of the normalized text;
  parallel branches union-merge, legacy `n_0001` ids valid forever), and
  `MemoryRepoInit.ensureGitSupport()` wired into the project store: the
  memory dir self-maintains `.gitignore` (derived artifacts never
  committed) and `.gitattributes` (`DELETIONS.md merge=union`).
- feat(memory): the `memory_add` tool description IS the memory repo's
  policy (`MemoryPolicy.memoryAddPolicy` —
  docs/memory/memory_add_policy.md): durable facts only, solved problems
  are superseded via delete+add instead of rotting, project scope is
  PUBLIC (committed to git — no secrets or personal data), user scope
  stays machine-local. One source of truth for every future agent.
- fix(build): CRAP ratchet green again — `MemoryController` delegates
  path resolution to `MemoryConfig` (one source, covered through the
  controller tests), and `AgentCli.run` sheds the retry-notice closure
  into `_wireTransientRetryNotice` (the 12.61 breach).
- docs(agents): the git-backed memory layout is documented in AGENTS.md
  (paths resolution, derived artifacts, id scheme, the commit
  convention: memory/ changes ride with the task's commit).

## 0.1.266

- feat(memory): project-level `.fah/config.yaml` — the `memory:` section
  now also resolves from the project's own config file and WINS over the
  user-level one, so the git-backed memory pointer travels with the repo:
  `memory: {projectPath: ./memory}` in `.fah/config.yaml` makes the
  repo's `memory/` directory the project memory for anyone who clones it
  (CLI and app, web keeps the default).
- feat(repo): flutter_agent's own memory moved into git — the full
  revision landed first (446 notes audited one by one; 142 deleted
  through tombstone `memory_delete`: 84 duplicates, 44 stale, 14
  superseded), the surviving 304 notes now live in the committable
  `memory/` directory with derived artifacts (`GRAPH.md`,
  `MEMORY.revision`, indexes) gitignored and `DELETIONS.md` under
  `merge=union`. `.gitignore` flipped from ignoring all of `.fah/` to a
  whitelist: `config.yaml`, `rules.yaml`, `lsp.json`, `mcp.json`,
  `agents/`, `skills/`, `packages.yaml` are committable;
  logs/sessions/bash_jobs stay local.

## 0.1.265

- feat(memory): configurable long-term memory storage paths — the new
  `memory:` section of `~/.fah/config.yaml` (`projectPath`, `userPath`,
  strict schema like the other sections) feeds `MemoryController`'s new
  storage-path overrides: a relative projectPath resolves against the
  project root, `~/` in userPath expands against the user home, and null
  keeps the historical `.fah/memory` layout. Point `projectPath` inside
  the repository (e.g. `./memory`) and the project memory becomes
  committable — anyone cloning the repo gets its memory. Wired in the
  CLI (`AgentCliConfig.memoryConfig`) and the app (`AgentService` reads
  the same section through a conditional IO/stub loader — web keeps the
  default). Step P0 of the git-backed memory program.

## 0.1.264

- fix(cli): macOS Cmd+Left/Right no longer types "aaaa" in the composer —
  those keys arrive as ^A/^E control bytes, and the dart_tui decoder puts
  the BASE LETTER into the event text, so every unhandled ctrl combo
  leaked its letter through the catch-all insert. Three insert paths
  (composer, picker type-to-filter, prompt re-shaper) now drop
  command-modified keystrokes (ctrl/alt/meta/hyper/super — shift stays,
  kitty-protocol shifted letters carry real text), and ctrl+a/ctrl+e do
  what the user meant: readline start/end of line.
- feat(cli): the `request_secret` sheet gets readline Ctrl+U — one
  keystroke clears the suggested name on name focus (the 16-backspace
  "erase SUDO_PASSWORD" nuisance) and kills the value back to the cursor
  on value focus; both hints name the key.
- test(cli): PTY visual coverage with screenshots — a real terminal run
  proves the composer edits (`Xhello worldYZ` after ^A/^E plus silent
  ctrl+x/g/z) and the full secret-sheet lifecycle end-to-end through a
  canned LLM that emits `request_secret`: suggested name, Ctrl+U clear,
  dot masking, Ctrl+R reveal, value kill, save — with the grant never
  echoing the secret into the transcript (screens 102–108).

## 0.1.263

- feat(cli): the `request_secret` TUI sheet can reveal the typed value —
  Ctrl+R toggles between the masked dots (default) and clear text, with
  the header line naming the current state (`value hidden (Ctrl+R
  reveals)` / `value visible (Ctrl+R hides)`). Long sudo passwords and
  tokens pasted into a blind field were unverifiable; now one keystroke
  shows what was actually typed before Enter.

## 0.1.262

- fix(providers): GitHub Copilot enterprise sign-in actually connects —
  the token exchange sent the legacy `Authorization: token <githubToken>`
  scheme, which `api.github.com/copilot_internal/v2/token` rejects with a
  bare 401 for enterprise-managed (EMU) accounts; pi's actively maintained
  `oauth/github-copilot.ts` uses `Bearer` for the exchange, and so do we
  now (OAuth device tokens are `gho_`/`ghu_` Bearer credentials). The
  account-type picker hardcoding also bit: an enterprise tenant's real API
  host lives INSIDE the exchanged token (`proxy-ep=proxy.<tenant>.github
  copilot.com`), so both the chat path and the `/models` listing now
  derive the tenant host from the token (pi `getGitHubCopilotBaseUrl`
  parity) and the picked tier host is only the fallback. The app gets the
  fix for free through the shared core exchange.

## 0.1.261

- feat(providers): transient network retry on every provider call — a
  Wi-Fi/VPN switch mid-turn killed the stream with "Connection reset by
  peer" and the turn ended in a hard error. `providerStreamFunction` (the
  one chokepoint for chat turns, roles chains, compaction summaries, and
  memory extraction) now wraps every adapter with
  `transientRetryStreamFunction`: a socket-level failure (reset / refused /
  unreachable / timed out / broken pipe / TLS handshake cut — certificates
  excluded, a bad cert never heals in 5s) sleeps 5s and replays the call,
  up to 3 attempts. omp's observable-output guard is kept: a stream that
  already emitted content is never replayed, so a retried generation can't
  duplicate text. The CLI surfaces each retry as a dim `[net] connection
  lost — retrying in 5s (attempt 2/3)` line plus an fa.log entry instead
  of a mysterious pause; `transientRetryNotice`/`transientRetrySleeper`
  are the host/test seams.

## 0.1.260

- fix(app): Copilot parity with the CLI — the app's model pickers now
  fetch through the copilot dialect (GitHub→Copilot token exchange,
  capabilities/limits) instead of 401ing the raw GitHub token against
  `<host>/models`; a picked Copilot model connects as the copilot wire
  dialect, and the entry-scoped `FA_KEY_COPILOT_<NAME>` key resolves as
  the fallback. Deleting a Copilot account now removes its entry-scoped
  token from the Keychain and the saved-keys store (before: only the
  shared `FA_KEY_<HOST>` slot went away and the token leaked); the
  duplicated name→key algorithm is gone — both surfaces use the one core
  `CustomProviderRegistry.copilotEntryKeyName`.

## 0.1.259

- feat(cli): fa.log now opens with `fa boot sid=… version=…` — the shared
  diagnostics log had no way to attribute a wedged "Working…" row to the
  BUILD that held it (today's 1949s spinner post-mortem stalled on exactly
  that: the wedged process predated the 0.1.255 busy-bracket fix, but only
  circumstantial evidence proved it). Every process now names its version
  next to its session id before any lifecycle line.

## 0.1.258

- fix(cli): the Copilot preset row now actually starts the connect flow —
  the "Add provider" picker shipped the row WITHOUT its handler
  (`null?.call()` closed the picker and nothing happened; the typed
  `/provider copilot` always worked). The handler map gained the copilot
  entry, and the picker test now asserts rows == handlers in BOTH
  directions so a dead row can never ship again, plus a line-mode routing
  test and a PTY visual test (screenshots 28/29/34) drive the real TUI
  from `/provider` to the "Copilot sign-in" step.
- fix(cli): `fa --session <name>` no longer opens another project's
  session — same-named sessions resolve with the LAUNCH folder first
  (a single local match wins); an ambiguous remainder (several in one
  folder, or none in it) auto-resolves to the most recently updated with
  a printed note naming every candidate id, the TUI offers the scoped
  "which one?" picker right after boot, and mid-session `/session <name>`
  asks with a numbered/wizard list. The switch itself now runs DETACHED
  under the flow gate (an awaited interactive pick deadlocked the
  sequential line REPL), redelivers lines typed during the switch instead
  of dropping them as flow junk, and redraws the idle prompt so the
  zeroed status meter shows.

## 0.1.257

- fix(cli): GitHub Copilot appears in the TUI "Add provider" picker — the
  preset list is hand-maintained and shipped without a Copilot row even
  though `/provider copilot` (device flow) worked; the row routes to the
  same connect command, and a picker test now pins every preset key to a
  handler so a future provider can't silently miss the menu.

## 0.1.256

- fix(cli): `/model <id>` on a saved CodeMie/custom entry no longer fails
  with 'no usable chain entry: set OPENAI_API_KEY' — the roles-mode pin
  carried the entry's key NAME, but the resolver's secrets never held the
  key material (the CodeMie JWT/SSO switch paths bypass the resolver), so
  the chain failed to resolve and the switch silently did nothing (the
  status line kept the old model). `_switchModel` now seeds the resolver
  with the session's live key under the pinned name (env-ring fallback)
  before pinning, and cookie-header auth (CodeMie SSO) keeps the direct
  model set — a cookie can never ride a Bearer chain.

- chore(sync): resolve the orphaned stash-pop conflicts to origin/main
- fix(cli): central busy bracket in _startRun — no more spinner-after-settle
- feat(fa_ui): always-visible custom answer in the ask sheet
- feat(apps): JsMediaHost wiring — video/audio nodes play for real
- fix(agent): abort wedged runs — SSE event-level idle watchdog + Agent.runIdleTimeout + fa.log run forensics
- feat(cli): env preconfig — required fields, base64 twins, all-roles default
- feat(app): chat text-size setting + dense markdown + unclipped copy
- feat(apps): adaptive layout host support (js_widget_runtime ^0.4.87)
- test(integration): fix latent env-key crash in real-model test
- feat(providers): Z.AI first-class + env-activated providers + FA_PROVIDER_* env preconfig

## 0.1.255

- fix(cli): the "Working… forever with an idle agent" wedge — the TUI
  busy bracket lived only in the submit handler, so runs triggered
  elsewhere (the idle inbox wake, a shell-job settle, a scheduled
  message) streamed with phase labels but released nothing: the spinner
  stayed on after the run settled. The busy bracket is now CENTRAL in
  `_startRun` (paired with the settle future) and the counter is the
  extracted, unit-tested `BusyDepth` — nested brackets (submit around
  run around wake) collapse to one edge pair. Forensics: fa.log showed
  `run end` with the spinner still up in two live sessions.

## 0.1.254

- **Wedged "Working…"/"Compacting…" turns now abort instead of hanging
  forever.** Two layered fixes after three live sessions (working,
  compacting, post-compact) pinned the busy row for 30-60 minutes with no
  recovery:
  - The SSE idle watchdog moved from the raw byte stream to a per-`moveNext`
    timer on decoded events: gateways keep dead generations alive with
    `: comment` heartbeat bytes, and the byte-level timer reset on every
    heartbeat — event-level silence is the honest signal. (`Stream.timeout`
    after the `async*` SseDecoder never fires at all — a Dart quirk this
    sidesteps entirely.)
  - New `Agent.runIdleTimeout` backstop (default 8 min, `Duration.zero`
    disables, `onRunIdleTimeout` callback): a run with no events outside
    tool execution is cancelled with a `TimeoutException` reason and ends
    as `aborted`. Streaming deltas re-arm, tool phases disarm — a long
    legitimate test gate never trips it.
- **Run-lifecycle forensics in `~/.fah/logs/fa.log`**: one line per phase
  transition (`run/turn/tool start|end`, `auto-compact start`, watchdog
  fires), each tagged with the short session id — a wedged busy row can
  now be attributed to the exact phase (provider turn vs named tool vs
  compaction) that never finished, across parallel fa processes.

## 0.1.253

- fix(cli): the busy row stops lying about compaction hangs
- feat(catalog): category filter chips above the widget list
- refactor(cli): split for the 2800-line size gate
- feat(providers): multi-account ChatGPT — per-entry keys, account picker, app parity
- fix(providers): review fixes — string-typed oauth json, pre-send cookie baseline, SSE incomplete/failed as stream events
- fix: drop duplicate models_for_endpoint import left by the main merge
- fix(codex): pin chatgpt catalog visibility; note review fixes in changelog
- fix(codex): terminate failed/incomplete SSE turns as error events
- fix(codex): serialize OAuth expiry as a string; decode stays tolerant of int blobs
- docs(goal): codex gpt auth — tick checklist, fill implementation log
- feat(providers): unhide chatgpt provider — ship docs, changelog, live smoke
- test(providers): chatgpt oauth token-leak guard — persisted registry + transcript carry no tokens
- feat(providers): codex models — live GET /models with bundled-catalog fallback
- feat(providers): codex http sse transport — header parity, cloudflare cookie replay, full event coverage
- feat(providers): chatgpt oauth expiry tracking — expiresAt + needsRefresh
- feat(providers): codex transport helpers — header parity, cloudflare cookie jar, rate-limit parsing

## 0.1.252

- fix(cli): the busy row stops lying about compaction hangs — the
  pre-flight compaction's 'Compacting context…' label no longer stays up
  for the whole run (a long tool call read as a compaction hang); the
  busy row now names the executing tool ('Running bash…') and drops back
  to 'Working…' between calls; resumed sessions drop generation-time
  usage anchors, so a compacted branch no longer phantom-reports its
  pre-compaction size (no more no-op compaction on every resume + an
  honest context gauge).

## 0.1.251

- feat(catalog): stacked equal-width action buttons on tile rows
- feat(launcher): Open menu item + icons, icon-square-only hover
- feat(app): interactive live tiles via widget.interactive opt-in
- feat(app): drop bundled demos — the catalog is the source of apps
- fix(app): actually pass sessionInfoNames to the sidebar (torn-write casualty)
- feat(app): the sidebar shows the CLI-written session_info names
- fix(app): reset/remove/install refresh the grid + sane dialog width

## 0.1.250

- feat(providers): ChatGPT goes multi-account — each account saves as its
  own named entry with its own name-scoped secure-store slot
  (`FA_KEY_CHATGPT_COM_<NAME>`, the CodeMie per-entry key pattern), so a
  refresh-token rotation never overwrites a sibling account's blob and
  the refresh callback writes to the ACTIVE entry's slot.
- feat(provider): `/provider chatgpt oauth` offers the saved ChatGPT
  accounts first (switch to one, or add another) before running OAuth;
  a NEW account gets a guided model pick from the live Codex `/models`
  (bundled default when the fetch answers nothing), while a re-login to
  the SAME entry keeps its last-used model.
- feat(app): the ChatGPT OAuth flow names the entry from the OAuth
  account's email (id_token claim) and matches re-auths by name +
  baseUrl — a second ChatGPT account lands in its own entry and its own
  entry-scoped Keychain slot, mirroring the CLI.
- feat(chatgpt): the ChatGPT provider (Codex backend) is now visible across
  the pickers and `/provider` — it ships with the real Codex HTTP SSE
  transport: Codex header parity (originator, session/thread ids, account
  id), cloudflare cookie replay, and a single challenge retry.
- feat(chatgpt): OAuth access tokens refresh proactively (expiry is tracked
  on the credentials blob) and the rotated blob is re-persisted.
- feat(chatgpt): reasoning deltas surface as thinking blocks;
  `response.incomplete` / `response.failed` end the stream as a terminal
  error event, preserving any partial text already streamed.
- fix(chatgpt): OAuth credentials `toJson` returns `Map<String, String>`
  again (expiry serialized as an epoch-millisecond string); decoding still
  accepts blobs with a raw int `expires_at`.
- fix(chatgpt): the cookie-replay baseline is the header the request
  actually carried (snapshotted before the send), so the single
  challenge retry fires only when the jar truly learned a new cookie.
- feat(chatgpt): `/models` probes the live Codex `/models` endpoint and
  falls back to the bundled catalog on 401 / challenge / malformed bodies.
- feat(memory): the long-term-memory LLM slot is wired — a new
  `HarnessLlmProvider` adapts fa_llm's `LlmProvider` onto the harness
  streaming contract and is resolved per call (`memory` role → `smol` →
  main) in BOTH the CLI and the app. Memory consolidation and semantic
  search now actually run instead of being silently skipped.

## 0.1.249

- fix(app): self-heal stale-catalog sha mismatches + card-ify the catalog list
- test(app): hold-release on a classic tile now expects the menu
- fix(app): installed widgets really swap Preview for Remove + tests
- fix(app): re-add the _localApps field declaration (clobbered again)
- fix(app): restore the _localApps field + refresh (clobbered mid-commit)
- feat(app): catalog sheet — Remove for installed, Created by me, real avatars
- fix(app): tile menu opens for plain icon widgets + right-click + soft hover
- fix(site): openPreview really uses the RUNNER url — the torn write had resurrected the /widgets/preview/ path
- fix(site): repair torn index.html (duplicate tail after </html>) + restore the app-only marks
- feat(site): platform widgets are marked 'runs in the Fa app' instead of a broken preview
- fix(site): preview iframe points at the jsr repo's own Pages runner
- feat(site): widget preview runs the real Flutter/jsr runner — DOM shim removed

## 0.1.248

- fix(cli): a run counts as busy from the moment it is STARTED, not from
  the first streamed byte — the inbox watcher / shell-job settle path no
  longer starts a parallel run during the pre-flight compaction window
  (live session showed `Bad state: Agent is already processing a prompt`
  right after `[auto-compacted]`).
- feat(app,widgets): catalog entries parse the optional `platforms`
  manifest field; the catalog sheet shows iOS/macOS platform chips.
- feat(site): widget gallery cards show platform tags and no longer wrap
  the size/`jsr ≥` text or the Preview/Download button labels.

- feat(provider): GitHub Copilot as a first-class provider — catalog
  entry plus the `/provider copilot` CLI flow (GitHub device flow with
  user_code + verification_uri, or paste an existing PAT; works
  headless) and the app's fa_ui Copilot connect sheet.
- feat(providers): Copilot protocol core in `lib/src/providers/` —
  `copilot.dart` (streamCopilot: token exchange, mandatory Copilot
  headers, errors-as-events), `copilot_oauth.dart` (short-lived token
  + header builder), `copilot_device_flow.dart` (grant + poll).
- feat(keys): entry-scoped `FA_KEY_COPILOT_<NAME>` secure-store keys
  with an env-first `_2`… ring — CI supplies keys without a store.
- feat(models): live copilot `/models` dialect — the GitHub token is
  exchanged for the Copilot token, capability/limit fields parsed.
- feat(provider): multi-account isolation — each GitHub account saves
  as its own named entry (`copilot-<login>`); re-auth updates only its
  own entry.
- fix(providers): copilot kind-dispatch audit — every provider-kind
  dispatch in lib/src now handles `copilot`: `inspect_image` streams
  through `streamCopilot` (GitHub token exchanged for the short-lived
  API token, never sent as the Bearer header) and the roles fallback
  chain accepts copilot entries (`providerStreamFunction` →
  `_CatalogStreamFunction` → `streamCopilot`). A single dispatch-chain
  test drives role takeover + inspect_image + /models in one run.
- fix(models): copilot /models limits override — the catalog's static
  copilot `contextWindow: 1000000` / `maxTokens: 32768` are wrong for
  several real models (400s from the backend); the endpoint-reported
  `capabilities.limits.max_context_window_tokens` /
  `max_output_tokens` now replace them per model when present, and
  the catalog defaults stay when the payload has no opinion.

## 0.1.247

- feat(tools): Hailuo 2.3 video dialect + headless pre-flight compaction
- fix(tui): key parser never swallows a trailing control byte into a text run
- fix(cli): restored sessions label the model with the pinned-key account

## 0.1.246

- feat(tools): `HailuoVideoDialect` — Hailuo 2.3 video generation on the
  MiniMax V1 contract (`POST /v1/video_generation` → poll
  `task_id` → `file_id` → `/v1/files/retrieve` → `download_url`),
  with size mapping (1080P/768P) and full MockClient flow tests.
  Dialect registry reordered most-specific-first: both MiniMax dialects
  share the `minimax` baseUrl marker, so the H3 dialect previously
  swallowed Hailuo endpoints into the wrong (V2) contract.
- fix(cli): headless runs compact BEFORE the first request — a resumed
  session already over the threshold went out over-window and the
  endpoint rejected the turn (the same pre-flight guard the REPL had).
- fix(tui): key parser never swallows a trailing control byte into a
  text run — a burst PTY read delivering `text\r` in one chunk ate the
  Enter into the text and the composer never submitted.
- chore: drop the build artifacts (`fa-local/bundle/…`) from git —
  `install_local.sh` rebuilds them and the directory was already
  gitignored (they were force-added once and churned 13 MB per install).

## 0.1.245

- fix(cli): restored sessions label the model with the RIGHT account
  too — 0.1.244 covered live switches via `_activeCustomName`, but a
  restarted session has none, so two same-endpoint accounts
  (`kimi-ira1`/`kimi_me`) still showed the first registry entry. The
  status label now disambiguates by the apiKeyName the persisted roles
  chain pins for the endpoint (`_endpointEntryLabel` +
  `_chainKeyNameFor`); the first-match scan remains the pin-less
  fallback.

- fix(cli): status bar labels model with the ACTIVE saved provider

## 0.1.244

- fix(cli): the status bar labels the model with the ACTIVE saved
  provider entry, not the first baseUrl match — two accounts on one
  endpoint (e.g. `kimi-ira1` + `kimi_me` both on
  `api.kimi.com/coding/v1`) used to show the first registry entry's
  name no matter which one was picked (`/model kimi_me` → status read
  `kimi-ira1/<model>`). `_statusProviderLabel` now prefers
  `_activeCustomName` and only falls back to the endpoint scan when no
  custom entry is active; the key resolution was never affected.

- fix(cli): media slot flow propagates custom provider keyName

## 0.1.243

- fix: gen_prompts trims description trailing newline
- fix: skip subagent integration tests when MiniMax key missing
- feat: v0.1.242 — MiniMax media picker fix + generate_video tool
- fix(provider): minimax /model picker shows the full catalog, not the saved modelId

## 0.1.242

- feat(catalog,ui): remote models catalog + thinking markdown + table CRAP fix (0.1.241)

## 0.1.241

- feat(catalog): remote provider-models catalog at `fa1.dev/models-catalog.json`
  preloaded once per process — fills `contextWindow` defaults the
  MiniMax-style `/v1/models` endpoint doesn't publish (M3=1M,
  M2.x=204800) and ships per-slot media-model lists
  (`imageGeneration`/`videoGeneration`/`speech`/`transcription`) the
  chat endpoint never returns. Pickers stay endpoint-driven: the
  catalog NEVER seeds the chat model id list (the provider's own
  `/v1/models` is the source of truth) — it only enriches metadata and
  the media slots. Endpoint-reported values always win; failures are
  silent (10s budget, never throws); pickers keep their manual-entry
  fallback. `RemoteCatalogEnrichment` (`lib/src/providers/`) is the
  host seam — preloaded from `bin/fah.dart` at boot.
- fix(tui): thinking-streaming deltas get inline markdown (bold,
  italic, inline code) inside their dim wrapper — reasoning snippets
  that quote function names or emphasise alternatives render properly
  instead of leaving stray `**…**` in the dim background. Renderer is
  a small single-pass scanner split into `_matchInlineSpan` +
  per-marker helpers (`lib/src/cli/ansi_markdown.dart`); block
  constructs (fences, headings, lists) still belong to `AnsiMarkdown`
  for full answers.
- refactor: `AnsiMarkdown._renderTableRows` split into
  `_tableFragments` / `_tableSeparator` / `_renderTableRow` /
  `_renderTableLine` — CC dropped, CRAP ratchet back to 12.00
  (pre-existing method was 16.27 at 69% coverage; now 12.00 at 100%).

- fix(compaction): 10-minute attempt budget — a hung summarizer can no longer wedge the turn (0.1.240)

## 0.1.240

- feat(catalog): remote provider-models catalog at `fa1.dev/models-catalog.json`
  preloaded once per process — fills `contextWindows` the endpoint
  didn't publish, suggests a `defaultModelId`, and ships per-slot
  media-model lists (`imageGeneration`, `videoGeneration`, `speech`,
  `transcription`) for providers like MiniMax whose chat endpoint
  doesn't return their media models. Endpoint-reported values always
  win; failures are silent (10s budget, never throws); pickers keep
  their manual-entry fallback. The catalog lives in
  `RemoteCatalogEnrichment` (`lib/src/providers/`) — preloaded from
  `bin/fah.dart` at boot.
- fix(tui): thinking-streaming deltas get inline markdown (bold,
  italic, inline code) inside their dim wrapper — reasoning snippets
  that quote function names or emphasise alternatives render properly
  instead of leaving stray `**…**` in the dim background.

- fix(compaction): a summarizer endpoint that accepts the request and
  never answers can no longer wedge the turn on the compaction spinner
  forever — every summarization attempt now runs under a 10-minute
  wall-clock budget (`AutoCompactor.attemptBudget`); the timeout fails
  the attempt (not transient — no retry spin), the pass falls through to
  the next summarizer or the honest local trim, and the turn goes on.
- fix(compaction): the emergency local trim zeroes the kept generations'
  usage anchors — a stale generation-time anchor kept the post-trim
  estimate over the window and retriggered the compactor every turn.
- fix(app,test): the whole quality gate goes green — CRAP ratchet, app suite, l10n and goldens (0.1.239)
- fix(replay): compact system-notice rows in restored transcripts (0.1.238)
- fix(provider): entry-name status label + persist catalog model picks (0.1.237)
- docs(goal): codex gpt auth — cross-platform notes (Rust portability does not transfer)
- docs(goal): codex gpt auth — point the reference at the open-source GitHub repo
- docs(goal): codex gpt auth — ship the ChatGPT/Codex-backend provider
- perf+fix: growing-tail throttle, codemie scoped key, status bar (0.1.236)
- docs(goal): copilot — translate to English, add tickable implementation checklist
- docs(goal): copilot — multi-account contract, mandatory TDD plan, Keychain-only tokens
- docs(goal): copilot provider — multi-account support as first-class scope
- docs(goal): add copilot provider goal — migrate copilot-proxy-go protocol into fa_llm
- deps: flutter_agent_memory ^0.1.1 (0.1.235)
- fix(memory): tombstoned delete via KBMemoryStore; hosted dep (0.1.234)
- feat: schedule_message + bash stdin param; crash hardening (0.1.233)
- perf(tui): O(1) in-place rollback of grown-tail arrays (0.1.232)
- perf(tui): flush streamed output every 16ms (0.1.231)
- perf(tui): cache formatted sticky echo rows (0.1.230)
- feat(memory): memory_delete tool; quote-style service blocks (0.1.229)
- fix(tui): add the missing system_notice_render import in fa_tui (0.1.228 fixup)
- feat(tui): render system notices as dim blockquotes with a gear marker (0.1.228)
- perf(tui): ASCII fast path + bounded line-width memo in tuiTextWidth (0.1.227)
- fix(tui): hoist terminal reset before SIGINT use; wire compaction delta tail (0.1.226 follow-up)
- fix(tui): restore terminal modes on Ctrl+C exit (0.1.226)
- fix(tui): keep the input caret visible while a run streams (0.1.225)
- fix(messaging): cross-project agent_message delivers to the recipient root (0.1.224)
- feat: instant key echo + Ctrl+C exits like /exit (0.1.223)
- fix(cli): visible hint after mid-run Ctrl+C abort (0.1.222)
- chore(tool): land the frame-build bisect probe (gitignored path)
- fix(tui): no-newline stream deltas stay incremental — typing lag gone (0.1.221)
- chore(tool): land the key-latency probe (path is gitignored)
- feat(tools): warn when a stale fa build writes old-format job logs here (0.1.220)
- fix(cli,compaction): paste-a-path sends, honest compact status, bounded extraction, per-delta ctx memo (0.1.219)
- fix(cli): FaTuiController stub carries setBusyPhase — web build compiles again
- fix(app,site): widgets entry points visible and verifiable
- docs(widgets): mark C2/M1 app-catalog milestone shipped with live checks
- feat(app): widgets catalog — install from fa_widgets releases, slim the bundle
- test(tools): assert shell job ids by shape after unique-id change
- chore(messaging): skip messages-registry write when unchanged
- fix(tools): collision-proof background job ids and image filenames
- fix(session): serialize JSONL writers per file and quarantine torn lines on open
- chore(local): rebuild fa-local bundle binary at 0.1.218
- fix(tui,fork): serialize tracer writes through a flush queue
- fix(tui,fork): FA_TUI_TRACE file sink flushes per event (crash-safe)
- perf(tui,fork): render-aware cursor dedupe — zero-byte idle frames
- perf(tui,fork): lazy frames, output dedupe, keypress-paint tracer
- fix(tui): replay restored messages in full — no per-message head caps
- fix(tui): wrap overflowing table cells — keep the box grid readable
- perf(tui,fork): drop-frame fps throttle — stop sleeping the event loop
- chore(vendor): inline dart_tui 2.0.0 under vendor/ for perf work
- perf(tui): amortized history-cap trim — no full re-parse per streaming flush
- feat(tui): truthful busy-row phase labels
- feat(cli): pre-flight context guard — compact BEFORE an over-window request

## 0.1.239

- fix(app): the macOS app builds again against the current core — the
  harness barrel now exports `ScheduledMessageQueue` +
  `scheduleMessageTool`, the service declares its `_scheduledMessages`
  field and arms the queue, the fabric repo's `root:` is a plain String,
  `_AutoCompactorFlutterHooks` implements `onDelta`, and the app's
  flutter_agent_memory constraint moved to ^0.1.1 (the stale lock had
  resolved harness 0.1.218).
- refactor(cli): the perf-sprint methods fit the CRAP ratchet again —
  pure extractions (busy-edge `sendBusy`, `_rollingTail`,
  `_maybeSwitchToSavedEntry`, fold-XOR fence scan,
  `_needsRewrite`/`_nextOpenTag`/`_taskOpenerEnd`, `_resumable`/
  `_tailThrottled`, `_replayUserTui`/`_chromeMarkerLine`); no behavior
  change. Max CRAP back to 12.00.
- test(app): the flutter_app suite is green under the hook again — the
  compaction-failure test matches the honest local-trim contract, the
  drawer tests drain the real-async lazy open, the map goldens skip when
  the demo moved to the widgets catalog, the ctrl+s visual test cancels
  the full `sh-<n>-<uniq>` job id, the /agents visual test seeds mail
  under the app-group sessions root, the corrupt-session test matches
  the quarantine-on-open heal, and `WidgetsCatalogSheet` passes the
  l10n + golden-coverage guards (new arb keys en/ru + two goldens).

## 0.1.238

- fix(replay): a restored `<system-notice>` message (background-shell job
  settle, inter-agent mail, task result) replays as ONE dim chrome line
  instead of the raw block — the full multi-line command dump, log paths
  and the closing tag no longer wall up the transcript after a resume.
  Mixed content still replays verbatim.

## 0.1.237

- fix(status): the provider shown next to the model is now the saved
  provider ENTRY name (z.ai, codemie-personal, …) matched by endpoint —
  the model's `provider` field carries the catalog protocol kind
  ("openai"), which read as "it switched to OpenAI" although the pick
  was z.ai.
- fix(provider): `/model` switches on catalog providers (no active
  custom entry) now persist the picked model — the host's onModelChanged
  fired only for saved-entry switches, so a restart restored the last
  provider switch's model (gemini from a codemie test) instead of the
  one the user chose.

## 0.1.236

- fix(roles): model switches on NON-catalog endpoints (CodeMie SSO, DIAL,
  self-hosted) resolve the endpoint-scoped store key
  (FA_KEY_<HOST>_<NAME>) even when the registry entry has no explicit
  keyName — SSO-cookie saves never set one, and the resolver fell back to
  the catalog env name (OPENAI_API_KEY), rejecting the chain ("no usable
  chain entry") and silently keeping the entry's saved model. The chosen
  provider's own token is now the ONLY candidate; expiry still triggers
  the silent browser re-auth. The catalog default endpoint keeps env-name
  priority.
- perf(tui): growing-tail throttle — a streamed paragraph whose last
  line keeps growing (a long thinking burst with no newline) re-formats +
  re-wraps that line on every 16ms flush, O(line length) per tick, which
  saturated the event loop and froze the screen (neither the thinking nor
  typed input rendered). Expensive tails (>8k chars) now re-render at
  ~10 Hz and complete instantly on the final newline; short lines and
  tests keep the byte-exact immediate path (debugTailThrottled counter).
- fix(codemie): the SSO wait now shows a live "still waiting…" status and
  bails after 5 minutes instead of hanging forever — the page usually
  signs in by itself (existing browser session), so the callback just
  needs patient waiting, not user action.
- fix(status): hide the $0.0000 price when the model has no cost data,
  humanize big token counts (12.3k / 4.6M), and show the provider name
  with the model in the status bar.
  MemoryRevisionService (+ MemoryRevision, ConcurrentRevisionException)
  are now public exports, so pendingDeletions/markConsolidated and the
  consolidate(expectedRevisionHash:) contract are reachable directly.

## 0.1.234

- fix(memory): `memory_delete` now goes through `KBMemoryStore.deleteRecord`
  (flutter_agent_memory 0.1.0) — tombstones + revision bump mean
  consolidation can no longer resurrect deleted entries; graph rebuilds on
  delete. `deleteEntityById` stays as a raw-storage escape hatch only.
- deps: flutter_agent_memory flipped from git tag to hosted `^0.1.0`
  (published on pub.dev) — unblocks fa's own future publish.

## 0.1.233

- fix(tui): a throwing update()/picker command can never close the app —
  dart_tui wraps model.update in try/catch (log + keep running), matching
  the existing runCmd guard. Cross-provider model switches surface errors
  as notices instead of dying (the CodeMie crash).
- fix(cli): stdout.terminalColumns/terminalLines fall back to 80/24 when
  stdout is not a TTY (session-switch replay crashed twice in crash.log).
- fix(tui): sendBusy is reference-counted — a second submit during a
  running turn (slash menus work mid-stream) no longer resets the elapsed
  timer + sticky echo, and its finally no longer kills the spinner of the
  live stream.
- feat(tools): bash gains a `stdin` param — text written to the command's
  stdin right after start (ask the USER for a passphrase via the ask tool,
  then feed it; ssh-add/sudo no longer hang on a raw prompt).
- feat(messaging): `schedule_message` — persisted delayed notes to an
  agent mailbox (self by default); pending records survive restarts and
  delivery rides the inbox idle-wake. Wired into the CLI and the app.
- deps: flutter_agent_memory 0.1.0 (git tag v0.1.0) — tombstoned deletes,
  timeout-guarded search, public graph-overview API.

## 0.1.232

- perf(tui): grown-tail rollback truncates the transcript arrays
  in place instead of sublist-copying them per streaming chunk — the
  per-chunk cost no longer grows with session length (the last
  time-coupled term; everything else is bounded or O(delta)).

## 0.1.231

- perf(tui): streaming flush interval 50ms → 16ms (~60 fps). A traced
  real huge session showed p50 frame build of 37µs, so flushing thrice
  as often is nearly free and streamed text (thinking included) appears
  smooth instead of in 50ms chunks.

## 0.1.230

- perf(tui): cache the formatted sticky echo. During a stream every
  keystroke forces a paint, and each paint re-ran markdown formatting
  over the entire echoed prompt — typing cost was O(echo lines) per
  key, painful with long prompts in big sessions. Rows are now formatted
  once per echo change (content+width keyed cache carried across model
  copies); view frames just write the cached bytes.

## 0.1.229

- feat(memory): `memory_delete` tool — remove stale entries by id
  (scan project then user scope, or restrict with `scope`); hosts get
  the prompt-section refresh hook like `memory_add`.
- feat(tui): `<task-result>` blocks and `[auto-compacted]` /
  `[context trimmed]` / `[memory maintained]` service receipts render as
  dim blockquotes with a ⚙ marker, same as `<system-notice>`.

## 0.1.228

- feat(tui): `<system-notice>` blocks (background-shell settlements,
  inter-agent mail) render as dim blockquotes with a ⚙ marker instead of
  raw tags — session notes look like notes. Model-visible records keep
  the raw tags; only the TUI view restyles them.

## 0.1.227

- perf(tui): width measurement fast path — printable-ASCII runs skip
  grapheme iteration entirely and a bounded whole-line memo (8192
  entries, insertion-order eviction) catches re-measured rows.
  Profiled with crap4dart on the transcript suite: wrapAnsiLine
  30.7s → 0.62s total (×49); tuiTextWidth/tuiGraphemeWidth dropped out
  of the top-10 hot methods; formatLine total 37.0s → 32.8s.

## 0.1.226

- fix(tui): Ctrl+C exit now restores terminal modes before exit(130)
  (mouse tracking off, alt-screen exit, cursor show) — the shell prompt
  no longer inherits mouse reporting, so wheel scrolling after fa quits
  stops printing escape garbage. The reset block is shared by the
  natural end and the SIGINT path.

## 0.1.225

- fix(tui): the input caret stays visible while a run streams. The old
  hide-while-busy guarded a pre-force-home artifact (the cursor jumping
  inside streamed text); the renderer now re-homes after every painting
  frame, so hiding only stranded invisible typing. Pickers and prompt
  dialogs still hide it.

## 0.1.224

- fix(messaging): agent_message to a peer in ANOTHER project now lands in
  the recipient's messages root. Delivery used to write into the sender's
  cwd-slug root, so the other fa (draining only its own root) never saw
  the mail — cross-project chats silently vanished. FileMessagingRepository
  resolves the mailbox's real root (messages-registry.json slug map, then
  a sibling-slug scan by .id marker); unknown ids stay local. Diagnosed
  live: a message fa<->crap4dart agent was found sitting in the wrong
  project's inbox.

## 0.1.223

- feat(tui): input-driven frames bypass the fps throttle — a keystroke or
  wheel event paints immediately instead of waiting out the ~18ms frame
  window (kitty's input_delay/repaint_delay split). Measured echo latency
  during a 500-delta/s stream over a 20k-line transcript: p50 12-17ms →
  0.1-0.2ms, p95 ≤0.4ms.
- feat(cli): Ctrl+C now exits exactly like /exit — aborts any in-flight
  run (bounded 5s wait), persists the partial transcript, prints the
  `fa --session '...'` resume hint to the real stdout, exits 130. Esc
  stays the abort-without-exit key inside the TUI. Adds
  AgentCli.waitForIdle (bounded settle) and sessionResumeHint.

## 0.1.222

- fix(cli): Ctrl+C while a run streams now prints "run aborted — press
  Ctrl+C again to exit". The first press always aborted the run but gave
  no feedback, so the suddenly-silent screen read as a hung process
  (PTY-verified: the SIGINT abort path works; only the hint was missing).
  A second press exits 130 as before.

## 0.1.221

- fix(tui): streaming without trailing newlines no longer force-rebuilds the
  whole transcript render — a delta that grows the current line (the
  coalescer's exact no-newline flush shape) used to break the incremental
  boundary's identity sentinel and trigger a full format+wrap pass
  (~220ms on a 150k-token transcript) on EVERY flush, saturating the UI
  loop so typing during a stream rubber-banded or froze. A prefix-extended
  tail now rolls the durable caches back one source line and resumes:
  measured 4327ms → 15ms over 20 growing appends; appends with newlines
  stay O(delta) as before.

## 0.1.220

- feat(tools): one-per-session warning when a freshly written old-format
  background-job log (`sh-<n>.log`, the pre-unique-id scheme) appears in
  this directory — proof a stale fa build shares the cwd and its job output
  can interleave with stale logs; surfaced as a loud CLI hint to restart
  that instance on the current binary.
- chore(tool): `tool/key_latency_probe.dart` — headless key-echo latency
  probe for the TUI (stream + burst + status-line scenarios), used to
  verify that typing during an active stream stays sub-frame on current
  builds.

## 0.1.219

- fix(cli): a pasted absolute path that EXISTS is sent as a message with the
  file attached instead of being refused with a "filesystem path, not a
  command" hint; a nonexistent path keeps the hint.
- fix(cli): auto-compaction reports honestly — a failed pass no longer
  prints the success-looking "[auto-compacted] N tokens summarized" line,
  and a no-op pass stays quiet.
- fix(compaction): emergency local trim — when both summarizers are down and
  the transcript is over the window, the most recent keepRecentTokens stay
  live behind a user-role marker (in-memory only; the session file keeps the
  full history) so the agent can keep working instead of being stuck
  over-window until the endpoint recovers.
- fix(cli): compaction-time memory extraction is bounded — the extraction
  stream is cancelled after 90s and force-skipped after 120s (the phase
  label no longer hangs for the whole role-chain retry ladder), and the
  "Compacting context…" phase is restored afterwards.
- perf(cli): the status line's context estimate memoizes the settled
  transcript by list identity + length only — the in-flight stream message
  is estimated per render and never invalidates the memo. Keying the memo on
  the stream's growing length used to force a full O(context) re-scan on
  EVERY streamed delta (dozens per second — the "typing lag" while a run
  streams over a large transcript).

## 0.1.218

- fix(tui,fork): the FA_TUI_TRACE file sink flushes every row — a traced
  session is the one you post-mortem, so a hard kill can no longer eat the
  trace tail. Opt-in only; zero cost when tracing is off.

## 0.1.217

- perf(tui,fork): cursor home dedupe is render-aware — a frame that painted
  rows force-homes the physical cursor exactly once; fully idle frames now
  emit ZERO bytes (the identical-content skip no longer pays the CUP).
- perf(cli): drop the nonce-SGR suffix from the idle cursor line — the
  renderer's render-aware re-home replaces it, so idle appends stop
  repainting the status row every frame.

## 0.1.216

- perf(tui,fork): dropped frames no longer build the view — `Program` now
  builds the screen lazily inside the frame budget check, so frames the fps
  throttle discards stop paying a full assembly for nothing.
- perf(tui,fork): renderer output hygiene — the window title OSC sequence
  and an unmoved cursor's CUP are emitted once (deduped, invalidated on
  clearScreen/alt-screen/scroll/insert) instead of on every frame.
- feat(tui,fork): keypress→paint tracer — attach `withTracer(...)` or set
  `FA_TUI_TRACE=<path>` to get an ordered JSONL timeline of stdin arrivals,
  drained batches and painted/dropped frames (`build_us`/`render_us`), for
  offline latency joins.
- perf(cli): the frame builder stops allocating a List<String> of every
  physical row per frame just to count lines (newline scan instead) and
  drops one full-screen string copy.

## 0.1.215

- fix(cli): restored sessions replay messages IN FULL — the per-message
  head caps (TUI: 20 rows, line mode: 2 rows) hid long answers behind a
  trailing ellipsis after a restart. The global row budget still bounds a
  marathon replay, but it now drops OLDER WHOLE messages instead of
  decapitating every entry; tool-call-only runs keep collapsing.

## 0.1.214

- fix(cli): wide GFM tables keep their box grid — cells wider than the
  terminal wrap onto aligned continuation rows instead of collapsing the
  whole table back to raw markdown; only a degenerate budget (tiny width,
  many columns) still prints raw rows.
- perf(tui): dart_tui vendored under `vendor/` and its fps throttle fixed to
  drop-frame semantics — an early frame no longer sleeps the event loop
  (~16 ms stalls per frame made typing/scrolling rubber-band during long
  streaming answers); drops repaint only the latest view via an internal
  RenderTickMsg, invisible to models.

## 0.1.213

- style(env): brace single-statement if in CwdOverrideEnv.backgroundJobsSupported

## 0.1.212

- fix(bench): drop stale fa_tui show-import from tui_stream_bench
- fix(tui): open-table boundary invariant — streamed tables never lose rows
- feat(site): widgets gallery page + machine index; widgets GOAL
- perf(tui): incremental transcript markdown+wrap — streaming flush x729 faster
- fix(cli,app): attach delivery, pasted-path attachments; split cli inbox part file

## 0.1.211

- fix(cli): a pasted filesystem path is not a slash command

## 0.1.210

- ci(mobile): skip the iOS artifact download when the IPA build was skipped

## 0.1.208

- feat(attach): live CLI sessions in the app — presence, 1:1 view, input handover

## 0.1.207

- fix(app): explain empty responses that follow an image-bearing prompt

## 0.1.206

- fix(app): skill discovery scans user-level roots (~/.claude, ~/.copilot, ...)
- ci(macos): tolerate an existing keychain when packaging the TestFlight PKG

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

## 0.1.204

- fix(providers): do not close shared HTTP client during OpenRouter OAuth exchange

## 0.1.203

- fix(cli): provider picker, CodeMie auth refresh, skills access
- feat(session): unify CLI and macOS app session storage
- fix(providers): restore Kimi endpoint (api.kimi.com/coding/v1) and default model k3
- fix(cli): auto-refresh expired CodeMie SSO cookie on startup

## 0.1.202

- fix(install): remove broken Dart fallback, respect FA_INSTALL_DIR, sign macOS CLI in CI

## 0.1.200

- fix(ios): correct force_load path — pod products live in a per-pod subdir
- fix(ios): force-load cupertino_http pod binary + CI gate on its FFI symbols
- fix(flutter_app): project mount sets agent cwd to /project so sessions are folder-scoped

## 0.1.199

- fix(cli): show auth-method picker when adding openrouter/codemie from TUI

## 0.1.195

- fix(install): macOS CLI bundle + quarantine/sign handling

## 0.1.194

- fix(ci): merge Release.entitlements into the signed macOS build, don't strip them

## 0.1.191

- feat(cli): add auth-method picker for CodeMie SSO/JWT and OpenRouter OAuth/key
- feat(cli): auto-restart CodeMie SSO when the saved cookie expired
- fix(cli): catch uncaught errors and harden provider switch against crashes
- fix(ui): make ChatComposer transparent and regenerate goldens
- fix(network): use platform HTTP client for sandbox env, allow local HTTP, log bookmark failures
- fix(macos): add app-scope bookmark entitlement and surface folder picker errors

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

## 0.1.187

- refactor(ui): sane Settings structure — providers include on-device, one Models group

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

## 0.1.185

- feat(tui): leave the mouse to the terminal by default (FA_TUI_MOUSE=1 to capture)
- fix(app): iOS CodeMie SSO — run the real loopback callback server

## 0.1.182

- test(messaging): drop unused import (dart analyze warning)

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

## 0.1.179

- fix(crap): simplify pickAgentAction dispatch; broaden badge visual soft-skip catch
- chore: drop unused session_repo imports
- feat(cli): extract active-agents badge to pure helper + unit tests; soft-skip live badge visual test
- fix(tui): soft-wrap long input lines instead of horizontal clipping
- feat(subagents): real JSONL child sessions at completion + /agents open <id> (race-free register)
- feat(providers): list-first model pickers everywhere — quick search, manual escape, agent models flow
- feat(cli): /agents child → Open session action — switch into the subagent's session

## 0.1.178

- feat(app): live agents badge in FaWorkBar (CLI bg: parity) + fix cli_visual tests for new settings hub order and /agents tree

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

## 0.1.175

- feat(providers): DIAL provider kind — `{baseUrl}/openai/deployments/{model}/chat/completions` with `Api-Key` auth, optional `DIAL_API_VERSION` query, `/openai/models` listing; `--provider dial --model <deployment>` headless

## 0.1.173

- fix(ci): restrict auto-release tag matching to v*.*.*; fix pubspec version
- feat(ui): auto-focus composer input on session open/switch
- fix(testflight): fail on submit errors; fix framework bundle IDs; cleanup publish job
- feat: switch to hosted flutter_agent_memory dep, remove publish_to: none
- chore: add LICENSE to fa_llm for pub.dev
- feat: prepare fa_llm for pub.dev publishing

## fa_llm-v0.1.1

- feat: switch to hosted flutter_agent_memory dep, remove publish_to: none

## 0.1.172

- fix(version): use Platform.resolvedExecutable so version works regardless of invocation path

## 0.1.171

- chore: trigger CI + auto-release for v0.1.171
- fix(ci): quote sed command to fix YAML syntax
- fix(ci): keep publish_to: none for analyzer; strip it only in the publish job
- fix(installer): rm -f target before cp — break symlinks so version.txt lives next to the binary

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

## 0.1.167

- chore: trigger auto-release for CLI binaries + subagents 2.0
- feat(ui): AppsPanel with search/filters/sections for wide-layout right panel
- fix: remove unused test class + imports causing CI analyze warning
- fix(crap): decompose + cover all new methods to pass CRAP ratchet (12.0)

## 0.1.164

- test(cli): avoid real network in /provider custom default URL test
- refactor(self_manage): lower fallbackZipUpdate CRAP and cover zip path
- ci: pin crap4dart to 0.2.1 to match pre-commit ratchet
- fix(installer): fallback to .zip extraction when raw binary not in release

## 0.1.162

- fix(app): key field no longer prefills OPENROUTER_API_KEY for non-OpenRouter providers
- fix(oauth): native iOS/macOS OAuth via HTTPS callback + custom scheme redirect
- fix(oauth): iOS web redirect flow with state + verifier

## 0.1.157

- fix(oauth): capture OpenRouter web callback via JS object postMessage

## 0.1.153

- feat(providers): Google Gemini media provider + MediaModelsSection in fa_ui

## 0.1.152

- fix(providers): voice sample URLs are case-sensitive on the CDN

## 0.1.149

- feat(apps): Language Tutor rewrite + fitness-trainer device-path probes

## 0.1.148

- Gate JS apps and skills by platform

## 0.1.147

- fix(macos): surface EventKit authorization failures
- feat(macos): allow explicit calendar permission bootstrap

## 0.1.146

- fix(macos): split Debug entitlements for local flutter run

## 0.1.143

- feat(macos): privacy prompts, configurable signing, and no-sandbox release for Fa

## 0.1.142

- macOS: no-sandbox release flavor, HealthKit support, privacy entitlements
- Local models heading, Gemma 128k context, context-fit budget fix
- feat(flutter_app): feature-gate WebLLM, expand Gemma context window, filter BYOK picker

## 0.1.141

- fix(macos): bundle LiteRT-LM companion dylibs for flutter_gemma

## 0.1.140

- feat(settings): show on-device providers in the Providers section
- feat(settings): voice selection for the TTS media slot

## 0.1.139

- docs(gemma): update platform comments for macOS support

## 0.1.138

- feat(gemma): enable on-device Gemma provider on macOS
- feat(fa_ui): wire fa_llm/fa_llm_flutter into provider config

## 0.1.137

- chore(deps): bump flutter_gemma to latest official releases
- feat(fa_llm_flutter): add FlutterGemma on-device provider

## 0.1.136

- Add fa_llm package extracted from flutter_agent_memory llm layer

## 0.1.135

- feat(fa_ui): providerId through the connect flow

## 0.1.134

- feat(fa_ui): userBubble/userBubbleBorder tokens in FaUiTheme

## 0.1.133

- feat(fa_ui): avatar builder + theme-driven chat surfaces
- feat(fa_ui): host surface tokens + optional app bar in FaChatScreen
- fix(fa_ui): FaChatScreen honors the host FaUiTheme in the chat theme

## 0.1.132

- feat(fa_ui): extract the agent chat into the shared fa_ui package

## 0.1.130

- feat(launcher): 'Restore reference version' tile menu item for demo apps

## 0.1.128

- fix(apps): jscore multi-instance crash override + seed-error surface + map top inset

## 0.1.125

- fix(example): pin js_widget_runtime@9498d0c — revert the native-release grace that defeated the lifecycle serialization (tf-6 SIGSEGV); drop the test-only grace config

## 0.1.123

- feat(site): TestFlight public beta link in the hero CTA row

## 0.1.120

- feat(fa_ui): present editor/picker pages as constrained dialogs on wide canvases

## 0.1.119

- feat(yoclip): Fa promo video workspace — 19s promo in 3 aspects x en/ru (App Preview + social + YouTube), creative treatment, VO, music bed, frame QA
- test(example): realistic providers in the store_providers frame; pre-commit format gate scopes to package dirs (yoclip/ is a standalone workspace)

## 0.1.117

- feat(example): launcher home on all layouts (legacy session sidebar removed), App Store shots v2 ('your own apps, built by chat'), golden orphan gate

## 0.1.116

- fix(example): close action for full-chrome JS apps (map was unclosable), store copyright name

## 0.1.114

- ci(ios): scope codesign rewrite to Runner, auto-sign the FaLiveActivity extension (bundle-id collision 90685)
- fix(example): steer button interrupts the run, queued steers run after stop, sheet opens at the latest message

## 0.1.113

- test(example): real-agent E2E on the macOS host + store promo artwork

## 0.1.112

- feat(example): iOS background execution + Live Activity, key resolution fix, crash-churn guard, mini drag pill

## 0.1.111

- fix(example): TestFlight SIGSEGV root cause — serialized engine lifecycle

## 0.1.110

- fix(example): visible run errors, mini last-message strip, iOS-grade drag&drop, weather timeouts

## 0.1.109

- feat: CRAP green zone (max ≤ 8), app integration tests, tool-dup fix

## 0.1.108

- fix(example): TestFlight JSC crash, ownership-aware demo sync, CRAP yellow zone

## 0.1.107

- docs: privacy policy — PRIVACY.md + published site page, onboarding links it

## 0.1.106

- feat(example): app content respects the bottom safe area + onboarding replay

## 0.1.105

- feat(example): icons-per-row setting, tight row gap, pager bounce fix

## 0.1.104

- fix(example): reliable tile drops, full-width grid, widget drag cards

## 0.1.103

- feat(example): first-launch onboarding, scene3d wiring + 3D game demo, sheet/tile polish

## 0.1.102

- feat(example): iOS-style home grid — icon-unit alignment, live reflow, resizable tiles
- fix(example): drop the border on the floating chat bar/icon — shadow only
- feat(example): tile span sizes + floating mini chat bar, directional sheet swipes
- feat(example): live app tiles on the launcher + chat sheet mini-by-default

## 0.1.101

- fix(example): sheet respects the top safe area + light-theme golden

## 0.1.100

- refactor(example): drop unused members left by the sheet v3 rewrite
- feat(example): sheet v3 — ONE panel: round icon ↔ mini bar ↔ full sheet

## 0.1.99

- fix(example): sheet UX — full-bleed, one surface, ghost panel gone

## 0.1.98

- feat(example): session chat sheet v2 — mini bar with input, smooth physics

## 0.1.97

- docs(example): AGENTS.md notes for the launcher home, chat sheet and shared composer
- feat(example): session chat bottom sheet over the launcher (pager, shared composer)
- feat(example): apps launcher home on narrow layouts (grid, folders, system tiles)
- fix(example): home control disambiguation (room/UUID) + duplicate-bridge-id write routing
- fix(example): preset carousel is full-bleed — cards slide behind the edges

## 0.1.96

- fix(example): Home + Health apps scroll — root column → listView

## 0.1.95

- fix(example): pin js_widget_runtime to git fix for JSC use-after-free (TestFlight crash)
- refactor(example): share chat message rendering with the in-app Fa overlay + full state goldens
- fix(example): Fa panel is one bottom sheet, never two stacked cards

## 0.1.94

- refactor(test): split agent_cli_test.dart into support + provider/model topical files
- fix(cli): spec env names resolve only for the default hosted endpoint
- fix: video download auth on own-origin urls + provider key name dedupe + keychain preflight
- fix(cli): fa update misdetects a native binary in pub-cache as pub-global

## 0.1.93

- fix(cli): empty Enter submits in guided flows; parse models[]/alias /models dialect
- docs: commit identity policy — ai.teammate for contributors

## 0.1.92

- feat(example): generate_video tool — async /videos job on the videoGeneration slot
- feat: request_secret tool — agent asks the user for missing credentials
- fix(example): theme-aware FaWorkBar — one component with the chat overlay
- fix(example): HomeKit entitlement + longer homes wait + notify probe
- feat(example): resume the day's session at boot instead of stacking empties

## 0.1.91

- feat(example): model presets wizard in settings
- feat(example): audio/video playback in the file preview
- feat(example): story-driven App Store screenshots with real photos

## 0.1.90

- fix(example): set the App Store copyright field in the deliver lanes

## 0.1.89

- fix(deps): revert sqlite3 to ^2.9.4 — 3.x build hooks break dart compile

## 0.1.88

- fix(example): retry deliver on Apple's bursty Connect API 500s
- fix(example): preflight the macOS store version before deliver
- fix(example): tolerate deliver's first-version 'No data' review-detail crash
- fix(example): shrink RU promotional text under App Store's 170-char limit
- ci: store-metadata workflow — App Store content upload on demand
- feat(example): App Store content pipeline — store goldens, metadata, fastlane lanes

## 0.1.87

- fix(example): iOS build — HMHomeManagerDelegate members shadow the homeManager global
- feat(example): HomeKit maximum API, empty-homes race fix, shareable debug logs
- feat(example): privacy-first analytics facade (Firebase Analytics)
- fix(example): contacts — system back steps out of detail, transient call hint
- feat(example): rename sessions, arbitrary agent keys, persist approval mode

## 0.1.86

- fix(example): regenerate iOS Podfile.lock (Firebase 12.x + media players)
- feat(example): calendar recurrence, alarms, calendars, span, and url
- fix(providers): thinking — dedupe reasoning vs reasoning_details + tail collapse
- feat(example): inline audio/video playback for sandbox media in chat

## 0.1.85

- feat(example): render sandbox images in chat — markdown imageBuilder + inline generate_image tiles
- feat(example): expand Fa chat in place inside JS app views
- fix(example): macOS pods — platform 14.0 + regenerated lock (Firebase 12.x)
- fix(example): in-app Fa stays in the bottom sheet on first contact
- chore(deps): update AI integration deps (firebase, flutter_gemma, js_widget_runtime) and sqlite3; migrate sqlite3 dispose -> close

## 0.1.84

- feat(example): preset default-model override + two-step media slot flow

## 0.1.83

- fix(example): drop the robot icon + Model header from the sidebar
- fix(example): macOS keychain read + dead platform channels
- feat(example): providers-first settings — provider editor page, default chat model flow, provider-based media slots
- feat(example): providers-first settings — provider editor page, default chat model flow, provider-based media slots
- fix(example): contacts list scroll + live search; paged full-list search with phone matching for dedup
- fix(example): composer stop button while streaming; abort drains steer queue into transcript
- chore(example): pin js_widget_runtime ^0.4.13 (image UA fix)
- fix(providers): dedupe overlapping/cumulative reasoning chunks in openai-completions thinking stream

## 0.1.82

- fix(example): browser-ish UA for network images (runtime 0.4.13) + url image probes

## 0.1.79

- fix: commit the missing modifications from models-config and media UI (autostash unstaging)
- feat(example): per-run date refresh, media models full-screen editor with /models picker
- fix(example): dead onPressed buttons (runtime 0.4.12), calendar date-labeled lists + ±7d match, mic e2e probes
- fix(example): current date in system prompt, foreground notification banners, contacts openUrl errors
- feat: CLI models-config (models: config + /models set|remove|config) + media models settings UI

## 0.1.78

- feat: Keychain key persistence (iOS/macOS), /models endpoint listing, model marks, site updates
- refactor(example): dedupe cache sections into shared model_cache_section; bump runtime 0.4.11
- feat(example): transcription slot wiring + read_video (frames → vision)
- feat(example): media models config + generate_image/speak/generate_music tools + js bridge
- feat(example): iCloud sync for sessions/apps (iOS; macOS pending signing)
- feat(example): local push notifications — channel, notify tool, js bridge, reminders demo
- feat(example): HomeKit control (iOS) + mic/ASR voice input
- feat(example): HealthKit read (iOS), scene3d dep (0.4.10), Android readiness doc

## 0.1.77

- feat(example): contacts domain — channel, agent tools, js bridge, demo app
- feat(example): jsr.fa.llm chat (multi-turn) + stream (delta events)
- feat(example): calendar write — channel, agent tools, js bridge, demo editing
- feat(example): back-swipe contract (jsr.onBack), privacy manifests + usage descriptions

## 0.1.76

- feat(example): chrome modes, branding sweep (fah→Fa), textArea+scrolling docs (0.4.8), system-API design doc

## 0.1.75

- feat(example): animation nodes demo (entrance stagger, animatedSwitcher), theme+reply-sheet sources
- feat(example): jsr.theme plumbing (light/dark live), Fa mini reply sheet, map-app golden
- fix(example): chart node API alignment (0.4.7), gridView docs, bar chart demo

## 0.1.72

- feat(example): orbit work-bar, light theme, secrets UI, open_app + calendar tools, map node demos

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

## 0.1.69

- fix(example): unblind hosted models — vision detection + settings checkbox
- feat(example): localize the UI (en/ru) with a hardcoded-string guard test
- perf(cli): coalesce streamed output deltas to keep typing responsive
- fix(cli): keep the ctx gauge at the last real usage after a failed run
- fix(example): bump js_widget_runtime to ^0.4.3 — renderer no longer crashes on array borderRadius
- perf(cli): memoize the markdown wrap pass so scrolling stays O(1)
- fix(cli): re-attach follow on submit so the sticky echo pins again

## 0.1.68

- feat(cli): render provider error lines in red
- fix(cli): hide the physical cursor while a run streams
- feat(example): follow-tail auto-scroll + collapse long thinking blocks
- fix(example): work bar for grid-opened apps; prove permission persistence

## 0.1.67

- feat(example): UX batch — collapsible tool output, Fa mark, in-app work bar
- test(example): textField onChange delivers typed text to JS
- fix(example): render attached-image messages — add the missing imageMessageBuilder

## 0.1.66

- feat(example): stream model thinking live into the chat
- fix(example): replace the whole-run timeout with an idle watchdog
- feat(example): SVG app icons for JS apps
- feat(example): restore persisted sessions in the sidebar after restart

## 0.1.65

- feat(example): teach the js-apps skill how to test apps before handover
- fix(example): fit the on-device Gemma context instead of engine overflow
- test(example): tap test — calculator key reaches the JS engine
- fix(cli): never hang on a keychain system modal
- fix(example): bundle demo app assets — nested asset dirs need explicit entries

## 0.1.64

- fix(ios,macos): keep -exported_symbol out of Debug link flags

## 0.1.63

- test(example): end-to-end render test for the calculator demo app
- feat(example): JS apps platform in the Fa app (js_widget_runtime)
- docs: document the wasm_run symbol gate, strip-style pitfall, and new CI secrets/caches

## 0.1.60

- fix(ios): export wasm_run FFI symbols so Release/TestFlight builds keep them
- ci: whitelist the tracked Firebase config for pub.dev's leak scanner

## 0.1.59

- fix(ios): use development provisioning profile for Debug builds
- ci: unblock releases — vendor gitignore rule, pubspec catch-up, tag-ahead release
- test(example): drop the unused accessGranted param (CI fatal-warnings)
- feat: widen shell PATH for GUI apps (Homebrew python/node)

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

## 0.1.52

- ci(ios): use absolute IPA path for TestFlight submit
- ci(ios,macos): fix submit artifact path and macOS Ruby PATH

## 0.1.51

- ci(ios,macos): fix artifact downloads and macOS keychain password
- ci(ios,macos): fix artifact path, macOS framework restore, action versions

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

## 0.1.49

- ci(ios): fix signing identity extraction
- ci(ios): use fastlane build_only with temporary keychain
- ci(ios): use persistent ci.keychain on self-hosted runner
- ci(ios): use only build.keychain as default/search list, no OTHER_CODE_SIGN_FLAGS
- ci(ios): import distribution cert into login.keychain and build without isolated keychain
- ci(ios): download Apple WWDR G3 intermediate into build.keychain
- ci(ios): import WWDR intermediate into build.keychain, keep it unlocked, pass --keychain
- ci(ios): pass --keychain to codesign via OTHER_CODE_SIGN_FLAGS and add debug output

## 0.1.48

- feat(cli): guided custom provider setup (`/provider custom`): api type
  (openai/anthropic/google-like), base URL, optional key (saved to the OS
  secure store), then the model — picked from the endpoint's `/models`
  list or typed manually; the TUI provider picker gains `+ custom
  provider…`. (Code landed inside 7082bc8, swept up by a parallel commit.)

## 0.1.47

- ci: explicit export-options plist for iOS builds (UUID + full identity)
- fix(example): pin the full signing identity name for iOS CI builds
- fix(example): pin CODE_SIGN_IDENTITY iPhone Distribution for CI builds

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

## 0.1.45

- feat(cli): fa update and fa uninstall quick commands
- fix(ci): quote pwsh run line — leading & parsed as a YAML anchor, breaking the whole workflow
- fix(windows): fa crash after TUI exit + installer mojibake
- ci: installer-smoke job runs the one-line installers on every tag

## 0.1.44

- ci: fix Windows binary build + installer mojibake

## 0.1.43

- feat: agent skills + project context files (all platforms)
- feat(cli): background subagents via the task tool
- fix(cli): keep cursor pinned to input while the spinner ticks
- ci: create GitHub Release before binary upload + embed version

## 0.1.42

- feat(cli): dart_tui interactive TUI with markdown rendering
- ci: add build-mobile.yml (APK/iOS) and build-macos.yml (DMG) workflows
- feat: multi-session support — AgentSessionManager (core) + FlutterSessionManager (app)
- fix(example): hide empty assistant bubbles in chat
- feat(example): debug-log system prompt platform and WASM runtime setup
- docs(example): drop stale no-WASM-on-iOS comments after static linking fix
- fix(example): iOS gets the full WASM sandbox command set in the system prompt

## 0.1.41

- fix(site): quote install URLs for zsh glob safety; refine iOS wasm_run static-library flags
- fix(cli): avoid double stdin subscription in TUI REPL
- fix(example): use DynamicLibrary.process for iOS wasm_run static linking

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

## 0.1.37

- fix(example): halve ONNX Gemma context window to 2048 (WebGPU OOM mitigation)
- feat: optional API token for custom providers (local servers need no key)
- feat(cli): banner shows baseUrl+key status, connection-refused hint, version in --help
- chore(example): ignore Firebase config files with real API keys
- fix(site): full-width header background and Fa branding
- feat(example): release prep — Fa branding, icons, bundle IDs, Firebase Analytics
- feat(cli): prompt overrides (config prompts: + --system-prompt[-file]) and full --help reference

## 0.1.36

- fix(example): WebLLM context windows sized for the Fa system prompt + compaction scales with model window
- feat(cli): headless mode — fa "prompt", -p alias, file-as-prompt (md/txt content, binary path ref)

## 0.1.35

- feat(example): persist last connection + downloaded-models quick start on setup screen
- feat(tools): lsp tool backed by the Dart analysis server (diagnostics/definition/references/rename)

## 0.1.34

- feat(tools): task tool — parallel subagents with schema-validated results (omp port)
- feat(agent): TTSR stream rules — abort, inject, retry mid-generation (omp port)
- feat(providers): model roles (default/smol/slow/plan) with fallback chains, key rotation, path overrides

## 0.1.33

- feat(tools): read selector grammar (:A-B, :A+C, multi-range, :raw) + zip inner paths + SQLite reads
- feat(tools): image read parity with pi (byte cap, pass-through, EXIF, placeholders) + transcribe_audio tool
- feat(site): set GA4 measurement ID

## 0.1.32

- feat(tools): web_search with provider chain (DDG keyless first, Brave/Tavily behind secrets) + web_fetch markdown extraction with a pub.dev site handler

## 0.1.31

- feat(tools): hashline edit format with content-hash anchors (omp port)
- feat(core): approval tiers with per-tool policy, bash interceptor, CLI/app prompt UIs
- feat(example): model lineup — drop <1.5GB presets, add Gemma 4 E4B ONNX (~5.2GB)

## 0.1.30

- feat(example): WebLLM presets refresh — Qwen3.5 + Qwen2.5-Coder (web-llm 0.2.84)
- feat(example): visible app name is Fa (assistant label, AppBar, transcript, system prompt)

## 0.1.29

- fix(example): transformers.js download filter+progress, SVG/upload/attach UX, provider-error robustness

## 0.1.28

- feat(example): central sandbox command registry drives the Fa system prompt
- fix(example): web upload fix + chat uploads→uploads/ + light HTML preview + session delete

## 0.1.27

- feat(example): transformers.js Gemma provider on web (ONNX q4f16, tools via prompt wrapper)
- feat(brand): rename visible brand to Fa + app favicon matches the site

## 0.1.26

- fix(example): Gemma web uses -web.litertlm builds + Gemma cache management in settings

## 0.1.25

- ci: coalesce auto-releases to <=1 per 2h + scheduled catch-up

## 0.1.24

- feat(example): brand app icon for all platforms (gradient >_ mark)

## 0.1.23

- feat(example): markdown/HTML file previews + auto-refresh on agent file mutations

## 0.1.22

- refactor(example): WebLLM goes chat-only + universal prompt-tools wrapper

## 0.1.21

- feat(example): Gemma provider on web via flutter_gemma litert-lm web (Gemma 4 tools in-browser)

## 0.1.20

- feat(core): prompt-based tool-calling wrapper (universal chat-model tools)

## 0.1.19

- fix(example): settings dialogs adapt to narrow phone screens

## 0.1.18

- feat(example): Gemma 4 on-device provider via flutter_gemma (iOS/Android)

## 0.1.17

- feat(example): custom provider management + WebLLM model cache management in settings

## 0.1.16

- feat(example): left sidebar (model picker + sessions), files move right

## 0.1.15

- feat(example): WebLLM function calling (tools for Hermes-3 FC preset)

## 0.1.14

- feat(example): branded web loading splash (first-frame fade)

## 0.1.13

- feat(example): dark theme matching the landing (terminal aesthetic)

## 0.1.12

- feat(example): full WebLLM preset list matching flutter_agent_memory (22 models)

## 0.1.11

- feat(example): WebLLM on-device provider for the web demo (no API key needed)

## 0.1.10

- feat(site): capability comparison table (Browser/macOS/iOS/Android/Windows)

## 0.1.9

- feat(example): web file upload + IndexedDB-persisted sandbox FS

## 0.1.8

- feat(site): SEO/GEO pack + OG share image

## 0.1.7

- fix(example): sharpen Ollama Cloud CORS guidance in BYOK notes

## 0.1.6

- feat(site): GitHub Pages landing + live web demo with BYOK
- feat(example): BYOK connection settings with provider presets

## 0.1.5

- refactor(prompts): extract LLM prompts to prompts/*.md + codegen (AGENTS.md convention)

## 0.1.4

- chore: mark fake PEM stubs as false_secrets for pub validation

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

## 0.1.0

- Initial project setup: package skeleton, quality gates (analyze, tests,
  coverage ≥ 80%, duplication < 1%), GOAL.md with the pi-mono port roadmap.
- Seeded `CancelToken` / `CancelTokenSource` / `CancelledException` — the
  universal cancellation primitive (Dart counterpart of web `AbortSignal`).

## 0.1.268

- memory: flutter_agent_memory roadmap hints (LLM role, graph screen, multi-root)
- feat(memory): flutter_agent_memory 0.2.0 — merge-friendly ids, git support, policy-driven memory_add (0.1.267)

## 0.1.269

- memory: maintain() leveling pass (level: 2 on 13 notes)
- fix(tui): immortal Working… spinner wedge — 100% CPU for 8h after run end (0.1.268)

## 0.1.275

- fix(compaction): bounded compactor budgets + attempt progress; loop over-window guard (0.1.274)
- feat(app): copilot connect picks the model explicitly; restart hydrates the entry-scoped key
- fix(agent): run watchdog disarms on abort; AgentService.dispose aborts in-flight runs (0.1.273)
- fix(providers): explicit model picks everywhere — no default models, copilot picker filter (0.1.272)

## 0.1.279

- fix(providers): reject Copilot fine-grained PATs at connect time (0.1.278)
- refactor(cli): split banner/key-status out of agent_cli.dart, untangle _runPrompt

## 0.1.281

- fix(providers): correct the Copilot token guidance — fine-grained PATs need the Copilot Requests permission (0.1.280)
- memory: copilot fine-grained PAT 404 root cause + flutter_app flame_3d env breakage

## 0.1.283

- fix(app): shared DapHubSnapshot, probe dispose ordering, scope reverts (#15 review)
- refactor(cli): one DapHubSnapshot type shared by CLI and app (#15 review)
- fix(app): compile fixes after main merge — barrel import hides, l10n key for widgets catalog note
- refactor(cli): extract packages.yaml loader into lib/ — keeps bin/ out of test coverage (CRAP gate)
- fix(cli): make dap opt-out test teardown race-tolerant
- fix(app): harden DAP hub page error paths and test determinism (#6)
- feat(app): DAP/Hub settings section (#6)
- fix(cli): review fixes for DAP/Hub /settings entry (#5)
- feat(cli): DAP/Hub entry in /settings (#5)

## 0.1.284

- memory: session access-count sync from trajectory work
- docs(trajectory): AGENTS.md sections for core, fa_ui widgets, CLI commands (#10)
- test(trajectory): fa_ui golden baselines (57 PNGs) + real icon glyphs (#10 phase 11)
- refactor(trajectory): CLI CRAP ratchet — split inspect renderer, cover tail/parse arms (#10)
- fix(trajectory): mirrored live-tail rows keep real-record durations (#10)
- feat(trajectory): Flutter host — service stream, feature flag, AppBar icon, panel (#10 phase 10)
- feat(trajectory): CLI /trajectory family + headless fa trajectory + TUI fallback (#10 phase 9)
- feat(trajectory): wire view, toolbar strings, barrel exports (#10 phases 6-8 integration)
- feat(trajectory): TrajectoryDetails tabbed sheet (#10 phase 8)
- feat(trajectory): TrajectoryTimeline painter + gestures (#10 phase 7)
- feat(trajectory): TrajectoryTable, per-kind cells, virtualised ledger (#10 phase 6)
- refactor(trajectory): split CRAP-heavy layout fold and timed timeline (#10)
- feat(trajectory): fa_ui controller, view skeleton, toolbar, strings (#10 phase 5)
- feat(trajectory): incremental full-text search index (#10 phase 4)
- feat(trajectory): timeline projection — sequence/duration/time/actual modes (#10 phase 3)
- feat(trajectory): event projection, request numbering, live tail, layout fold (#10 phase 2)
- feat(trajectory): core record model, snapshot contract, JSONL walker (#10 phase 1)

## 0.1.285

- fix(trajectory): timeline lane labels inherit theme font
- test(trajectory): real fonts in fa_ui goldens — Inter/JetBrainsMono + monospace alias

## 0.1.286

- fix(trajectory): thread ToolCall.parentCallId so subtool rows replay from sessions

## 0.1.287


- feat(tools): capability-gated tool availability (issue #19) — the pure
  decision layer (`lib/src/tools/availability.dart`: `ToolsConfig` yaml/JSON
  parsing with `mcp:<server>` flattening, `resolveToolAvailability` merging
  the global < project < session < runtime scope stack over the host's hard
  capability floor — absent tools can never be force-enabled, unknown ids
  warn once) and the gate (`availability_gate.dart`: idempotent registry
  hide/restore + prompt rebuild, executor tombstones for calls to disabled
  tools, `noteHiddenNames` covering late MCP registrations).
- feat(cli): the `/tools` family (bare list, `enable|disable <id>
  [global|project|session]`, `reload`), a Tools entry in the `/settings`
  hub, and the runtime scope: `--tools 'id=on|off,...'` with the `FA_TOOLS`
  env twin (flag wins; a malformed spec is a hard startup error). Scopes
  re-read and re-applied live — no restart; a broken scope file keeps the
  last good one with a warning.
- feat(dap): the `dap_*` tools register only when a hub is actually
  configured (env > `hub:` section > `~/.dap/config.json` > default) — the
  zero-config install hands the model no dead-end tools; `/dap <host>`
  still connects on demand and the tools appear at the next launch.
  `dap: false` in any `tools:` scope turns the family off.
- feat(app): a Tools section in the app settings — one live switch per
  known tool id (ids the app cannot wire render disabled with the
  capability's reason), applied to the running agent without a restart and
  persisted as `tools_availability.json` via the new `ToolsAvailabilityStore`
  (the same `ToolsConfig` JSON envelope the CLI parses).
- feat(read): the `read` tool follows the `sqlite` availability decision —
  its description carries the SQLite section only while sqlite is enabled,
  and the variant swap re-registers in place (shared snapshot store, so
  hashline anchors recorded by either variant validate for `edit`).

## 0.1.290

- release: 0.1.289
- release: 0.1.282
- memory: supersede stale CPU-storm notes, record hub-test flakiness
- feat(roles): retry transient transport failures instead of killing the turn
- fix(app): onboarding dark theme — themed provider cards, dots, badges
- deps: switch to fa_hub_client 0.2.8 (hosted) — the published backoff fix
- deps: fah_hub_client 0.2.8 from the IstiN fork — backoff overflow fix (CPU storm)
- feat(cli): tell the agent about local ! commands via a steering notice
- fix(cli): steer file-prefixed busy input; run/drop leftover steering loudly
- fix(tools): media slots never inherit the main provider key; generate_image surfaces MiniMax base_resp errors
- memory: CPU burn investigation notes
- feat(cube): fa1.dev registry client, /cube templates + /cube install
- feat(cli): cube sandbox settings picker lists the built-in security presets
- feat(cube): resolver falls back to built-in security presets by id
- feat(cube): built-in security-level presets (L1-L3 x core/full) with tests
- fix(tui): shift+enter via legacy ESC CR wire (alt+enter); pin keyboard-protocol contract
- fix(tui): kitty shift+enter newline; cap streamed tail line growth
- memory: note that origin is a local file mirror (no GitHub remote)
- fix(cli): approval note Ctrl+U; hoist per-keystroke regexes
- test(cli): pin line-mode /exit-during-run interleaving
- fix(providers): strip a leading UTF-8 BOM in the SSE decoder
- chore(test): drop leftover PTY debug screenshots
- memory: session notes from the tui/gateway/debugging fixes
- feat(memory): hot-reload the memory config at runtime
- fix(cli): folder paths stay messages; session switches re-apply folder model memory
- fix(cli): slash and bang commands execute while a run streams
- fix(tui): backspace erases typed note characters in the approval prompt
- fix(tui): keep the history-cap trim fence-balanced
- test(integration): PTY proof for the approval selector and git-prompt fail-fast
- snapshot: local tree 2026-09-02, grafted onto upstream 30ac68b4 (repo line was rootless)

## 0.1.291

- ci(publish): honor publish_to: none instead of failing every tag

## 0.1.292

- feat(widgets): live state sync between board tile and fullscreen app + 1x1 icon tiles

## 0.1.293

- redact: stage 2 — agent hook wiring for the layered pipeline (issue #24)
- feat(redact): layered redaction pipeline core (issue #24 stage 1)
- feat(pub): publishable again — hosted dart_tui dep, vendor stays local
- feat(app): Copilot provider entries re-auth via the device-code flow
- fix(app): launcher tile labels no longer glued to the icon square
- fix(app): onboarding page 3/4 mockups readable in dark mode + light goldens

## 0.1.298

- test(ollama): diagnose live forced-tool-call null args instead of a bare cast

## 0.1.299


- feat(browser): the browser extension (issue #23) — `browser_ext/` (Chrome
  MV3) pairs a local fa with the browser over a loopback WebSocket bridge
  (`fa serve --bridge [--port N] [--token T]`, `/browser connect|status`):
  wire protocol v1 client (hello/welcome, 1s→30s reconnect backoff,
  offline outbox, msgId dedupe, ping keepalive), one-time 32-byte pairing
  tokens (`.fah/bridge/token`, mode 0600, rotated by every connect,
  constant-time compare, non-`chrome-extension://` origins refused, AC15),
  two-way mail relay over the file messaging fabric
  (`browser-ext/<agentId>` mailboxes). Eleven `browser_*` tools over the
  bridge (navigate/tabs/switch_tab/click/type/press_key/select/read_dom/
  eval/screenshot/wait_for, exec tier, availability-gated under the
  `browser` + `browser_eval` ids — hidden until an extension pairs,
  docs/tool-availability.md). Two control planes: quiet content-script DOM
  ops by default, per-call `trusted: true` chrome.debugger path (E23
  denied when DevTools owns the tab, any-tab screenshots via
  Page.captureScreenshot, AC16) with the debugging infobar as the honesty
  signal; task tab groups (`fa — <task>`) close agent-opened tabs on
  task_end or bridge disconnect (AC17). Self-contained mode: dart2js build
  of `browser_ext/dart/` (`scripts/build_browser_ext.sh` → sw/agent.js +
  build/fa-extension.zip) runs the agent core inside the service worker —
  panel provider form (OpenAI-compatible endpoints; deterministic `fake:`
  provider for tests), approval banner (30s timeout = deny), JSONL session
  + compaction in chrome.storage, no shell (`shellUnavailable`), keys read
  only inside the SW (AC8). The embedded agent joins the DAP hub with an
  E2E-encrypted CLI-compatible identity (`faDapKey`): `dap_peers`/`dap_dm`
  tools, one mail deduper across bridge + hub links (AC18). Headless CI:
  `test/browser_ext/` (real Chrome via `--load-extension`,
  `--headless=new`; integration-tagged) in `.github/workflows/
  browser-ext.yml`; unit layers `dart test test/browser/`,
  `browser_ext/dart` dart test, `node --test browser_ext/test/`. Docs:
  docs/browser-extension.md.

## 0.1.300

- fix(aiin): open the web sign-in popup inside the tap gesture
- fix(app): drop the duplicate aiin_connect_flow golden-guard exemption
- fix(app): drop a duplicate golden-guard exemption key; memory: session notes
- feat(aiin): one-click web sign-in — the OpenRouter-style popup flow
- test(redact): pin the agent file-reading scenarios end to end
- docs(AGENTS.md): name-based addressing in the messaging fabric bullet
- fix(redact): entropy layer stops shredding paths, hashes and lockfile integrity
- test(app): regenerate goldens after AIIN-hosted form changes

## 0.1.301

- feat(aiin): paste-key fallback — the service now blocks our redirects
- memory: session notes
- feat(skills): bundled create-goal skill — goal-writing discipline as /create-goal

## 0.1.302

- feat(aiin): official aiin.by mark, identity-provider picker, model search
- test(redact): integration e2e for issue #24 AC5-AC8
- fix(aiin): Safari popup — no awaits before window.open, paint the popup
- test(redact): integration e2e for issue #24 AC5-AC8

## 0.1.304

- fix(publish): assemble the redaction e2e PEM fixture at runtime — pub.dev's
  key-leak validator rejected the 0.1.303 upload because the archive carried
  a literal (fake) private-key block in `test/integration/redaction_e2e_test.dart`;
  the file now builds the same byte-identical string from chunks.
- fix(roles): 500-class gateway errors ("Internal network failure, please try
  again later") now classify as transient transport failures and retry in
  place with backoff before failing over (previously only 502/503/504 did).
- feat(messaging): agent_directory rows show an 8-char short id, session
  names, last-activity ("active 2m ago" vs "asleep") and home-shortened cwd;
  `agent_message` to an asleep target launches a detached headless run of
  that session so pending mail is processed immediately (wake: false opts
  out).
- test(cli): pin session-start memory maintenance off in boot-race tests
  (CI flake: consolidate() consumed the scripted turn before /exit).

## 0.1.303

- fix(roles): classify 5xx internal errors as transient transport failures
- feat(messaging): readable agent_directory + auto-wake for asleep mailboxes

## 0.1.305

- feat(aiin): use the hosted AIIN sign-in page as the connect entry

## 0.1.306

- ci: workflow_dispatch for ci.yml — manual gates when pull_request can't fire

## 0.1.309

- fix(cli): skill autocomplete for partial skill names — typing /goal or
  /skill:goal in the TUI composer now offers /create-goal (the raw-prefix
  match broke on the embedded slash), the accepted item still inserts the
  canonical `/skill:<name> ` form.

## 0.1.308

- fix(roles): provider watchdog timeouts ("TimeoutException after 0:03:00:
  Future not completed", "request timed out") classify as transient
  transport failures — retried in place with backoff, then failover to the
  next chain entry, instead of killing the turn (YoClip agent report).

## 0.1.307

- fix(widgets): unique router instanceId per engine — frozen tiles and dead buttons

## 0.1.312

- fix(compaction): the summarizer-down local-trim valve no longer wedges the
  session — a token-boundary cut could land between an assistant tool call
  and its result, leaving an orphaned ToolResultMessage that made strict
  providers reject every following request ("400: tool_call_id is not
  found", Kimi). The trim now advances past leading tool results.

## 0.1.311

- fix(messaging): scheduled self-reminders actually arrive — 'self' was never
  resolved to the agent's mailbox, so schedule_message fired on time and then
  the mail vanished into a phantom `<root>/self` inbox; start() now migrates
  the stranded legacy mail into the real mailbox. Cross-mailbox `from`
  attribution fixed; parseDelay `ms`/fractional units fixed ('90ms' was 90 s).
- feat(cli): terminal visibility for scheduled messages — dim '[sched] in
  25m: <text>' when the agent schedules one and '[sched] fired: <text>' when
  it fires.

## 0.1.310

- refactor(cli): move trajectory view additions out of agent_cli (file size guard)
- fix(windows): restore generated plugin files stripped in #31 (review)
- fix(trajectory): close audit findings — focus consumption, keyboard copy, a11y, safe-area, CRAP (#25)
- test(trajectory): regenerate toolbar+layout goldens, refresh AGENTS.md (#25)
- feat(trajectory): integration — export menu, request persistence, guard closed (#25)
- feat(trajectory): real-content feed rows, guaranteed details, Gantt timeline (#25 L3-L6)
- feat(trajectory): full-screen adaptive shell + header (#25 L1-L2)
- feat(trajectory): data completeness for the ledger view (#25 L7)
