# SDK subsystems (lib/ — flutter_agent_harness core)

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.


- `lib/` — the `flutter_agent_harness` package (pure Dart core). `test/`
  mirrors it. `prompts/` — all LLM prompts as Markdown (rules: docs/agents/prompts.md).
- `tools/fa-clip/` — the native macOS pasteboard helper (gh-2040): a plain
  `NSPasteboard` reader (`fa-clip <png|jpeg|tiff>` → bytes on stdout, exit
  2 = flavor absent), built by `scripts/build_fa_clip.sh` into the macOS
  CLI bundles (`bundle/bin/fa-clip`, per-arch) and shipped beside the `fa`
  binary — install.sh, install_local.sh and the self-update swap all copy
  it. The CLI resolves it relative to its own executable, never PATH; a
  missing/broken helper degrades to the named pasteboard-unavailable path.
  NEVER reintroduce the AppleScript/Apple Events clipboard transport
  (`osascript` is grep-gated out of `bin/` + `lib/src/cli/` —
  test/cli/fa_clip_helper_test.dart); the TCC «access data from other
  apps» dialog class must stay dead. macOS text reads stay on `pbpaste`
  (already prompt-free — documented split, gh-2040 AC4).
- `lib/flutter_agent_harness.dart` (the barrel) — gh-1232 policy:
  GROUPED APPEND-ONLY export sections, one `// ── <subsystem> ──` comment
  header per group, exports sorted by path within a group, new exports
  appended to their subsystem group (a new subsystem starts a new group).
  No per-subsystem mini-barrels, no re-sorting of existing lines — append
  only, so parallel edits almost never touch the same line.
- God-file ceiling (gh-1232): no Dart file over 2800 lines anywhere
  (crap4dart `loc` gate, `max_lines: 2800` — issue #1234 migrated the
  shell guards; enforced whole-tree in CI and on staged files by the
  pre-commit hook. Scope: core `lib bin` via `crap4dart.yaml` +
  `test example` via the `crap4dart.loc-scope.yaml` companion config
  (0.11.0 has no per-gate sources override), flutter_app/lib via
  `flutter_app/crap4dart.yaml`).
  Target < 2000 for primary
  files; when a file approaches it, split by concern into `part` files
  (the established pattern: `agent_cli.dart`, `builtin_tools.dart`,
  `bin/fah.dart` → `bin/fah_*.dart`, `agent_service.dart` →
  `agent_service_*.dart` mixins) — never by extracting public API.
- `lib/src/approval/` — tool approval gate: tiers (read/write/exec),
  session modes (always-ask/write/yolo/autopilot — the CLI label of the
  `unattended` enum), per-tool overrides,
  critical-pattern
  `bash` interceptor, per-turn grants (`grantForTurn(allow:, deny:)` —
  skill `allowed-tools`/`disallowed-tools` manifest keys ride these for one
  turn; explicit deny > turnDeny > per-tool override > turnAllow >
  alwaysAllow > mode (critical bash outranks mode in always-ask/write/yolo,
  but is skipped in unattended so the mode never blocks — for runs with no
  user present); `clearTurnGrants()`
  on every new user
  message). Wired via `attachApproval` into `beforeToolCall` (runs
  first); prompt UI is an injectable `ApprovalPrompt` (null + prompt policy
  = deny).
- `lib/src/tools/ask_tool.dart` — `ask` tool: structured mid-turn questions
  via injectable `AskCallback` (null = error, cancel = plain result).
- `lib/src/tools/request_secret_tool.dart` — `request_secret` tool: the agent
  asks the USER for a missing credential via injectable
  `RequestSecretCallback` (never in chat text); a grant returns
  `RequestSecretResult` (host-adjusted `name`, `value`, `persisted` flag),
  a decline is a plain result. The app wires it in `AgentService` to
  `secretRequestHandler` (chat screen installs
  `ui/widgets/secret_request_sheet.dart`): a grant is persisted into
  `SessionKeysStore`, injected into the live shell env via
  `SecretsExecutionEnv.addSecrets` (the map is runtime-mutable now), and
  registered into the same `SecretRedactor` — so the next run's prompt name
  list, bash `$NAME`, and redaction all pick it up.
- `lib/src/env/session_vars_execution_env.dart` — `SessionVarsExecutionEnv`:
  an `ExecutionEnv` decorator injecting session-correlation env vars
  (`FAH_SESSION_ID`/`FAH_SESSION_FILE`/`FAH_PROVIDER`/`FAH_MODEL`, resolved
  live per `exec`, never secrets) into bash tool executions. Wired around
  `builtinTools` in the CLI (`AgentCli`) and the app (`AgentService`).
  `LocalShell` merges `ShellExecOptions.env` OVER `Platform.environment`
  (never replaces), so injected vars keep the inherited environment.
- `lib/src/env/io_execution_env.dart` — `LocalShell`: foreground `exec`
  runs under `setsid` when the host has it (probe
  `ownProcessGroupAvailable`, seam `ownProcessGroupOverride`) and the
  timeout/cancel paths reap the whole tree (`killTree` + direct-kill
  backstop) with a capped pipe-drain (`_drainGrace`) — timeout/cancel'd
  calls complete in ≤ timeout + kill grace + drain grace; a no-timeout
  call within `_drainGrace` of the direct child's exit (the drain is
  capped unconditionally: after the child is reaped every remaining pipe
  byte comes from an orphan). Killed calls are marked `timeout`/`aborted`
  and carry the captured partial output on `ExecutionError.stdout`/
  `stderr` — tail-capped at the source to the last 64 KiB (`_captureTail`)
  — rendered by the bash tool and the skill renderer's `!cmd` failure
  branch (every string that branch embeds is tail-capped to ~2 KB)
  (gh-1053; the timeout timer stays
  armed after the child exits because an orphaned descendant can hold
  the pipes — a drain that outlives the deadline marks the call
  `timedOut` even when the child exited 0). Background jobs (issue #517)
  keep their own group + `stop()` semantics. Self-signal immunity
  (gh-1763): POSIX scripts are delivered from a per-exec private temp
  file (`sh -c '. "$1"' sh <script>` — prelude restores `sh -c`
  positional-param parity, so `$0`/`$#`/exit codes/`set -e`/stdin are
  unchanged; legacy `sh -c <command>` fallback when the temp dir cannot
  be created) so the wrapper argv never carries the script body —
  `pkill -f <pat>` inside a command cannot match its own shell; a
  provisioned-once guard (`lib/src/env/bash_guard_io.dart`) puts
  `pkill`/`killall` PATH shims at the head of PATH plus a `kill()`
  prelude function, both excluding the harness pid chain + process group
  (exported as `FA_PROTECTED_PIDS`, overridable per exec via
  `ShellExecOptions.env` for tests) and the invoking shell, while
  legitimate victims stay killable; Windows keeps `cmd /c` verbatim.
  Residual caveat: shapes the shim cannot model — output modes
  (`-c`, `-v`, `-l`, `-a`, `--count`, any other long option), a signal
  spelled after the pattern, extra operands, or a selection pgrep
  rejects — exec the real, unshimed binary and are NOT covered by the
  exemption (keep the pattern away from the harness cmdline in those
  spellings).
- `lib/src/tools/checkpoint_tool.dart` — `checkpoint`/`rewind` tools:
  context hygiene for detours. `CheckpointRewindController` wraps
  `Agent.prepareNextTurn`, persists via host `CheckpointSessionSink`.
  Lifecycle (issue #286): a checkpoint is scoped to its detour — when the
  next `checkpoint` call finds it stale (a user turn arrived inside the
  detour, or the anchored span was rebuilt away by reload/compaction), it
  is auto-closed with a note + `checkpoint_auto_closed` session record
  instead of refusing; `rewind` semantics are unchanged.
- `lib/src/compaction/branch_summarization.dart` — `generateBranchSummary` +
  `navigateSessionTree` (use instead of `Session.moveTo` for tree
  navigation); summary is a `branch_summary` record on the entered branch.
- `lib/src/agent/tool_pairing.dart` — context pair-integrity (issue #85):
  `validateToolPairing` checks the wire-equivalent message sequence (orphan
  results, unanswered calls, duplicate ids, displaced results after
  same-role merges); `repairToolPairing` fixes the outbound payload only
  (drop orphan + one-shot note, synthesize interrupted results, hoist
  steering text after results, uniquify duplicate ids symmetrically on
  call+result). gh-1449: the drop note never costs the model a turn — it
  rides the payload's LAST existing user message as an extra text block
  (degenerate no-user-message payload degrades to the legacy standalone
  note), names tool/id/cut/kept-in-summary, and fires ONCE per orphan:
  `orphanReportKey` (canonical id + tool + timestamp) latches in
  `Agent.reportedOrphanKeys`; hosts persist each first-time batch as the
  hidden `orphan_report` custom record and seed the latch back at resume
  (CLI `_loadSession`, app `loadSession`).
  `agent_loop.dart` repairs before every request and retries once on a
  pairing-shaped provider 400 (`ToolPairingRepairEvent` is the audit
  trail; its report carries `notedOrphanKeys` — the wire frame is
  optional-field backward-compatible); `_finishStreamed` stamps per-run
  position-counter ids session-unique; `auto_compactor.dart`'s
  `_localTrimFallback` routes the kept region through the same repairer.
- `lib/src/agent/image_registry.dart` — session image registry (issue
  #171): unique images ride a provider request exactly once; every other
  occurrence becomes a `[Image N]` text ref. `rewriteHistoryImages`
  rewrites the OUTBOUND payload only (session JSONL byte-identical);
  carriers `[{text:"[Image N]"},{image}]` anchor before the first
  referencing user message or after the tool-result run (never inside
  call/result pairs); the current user message rides images in place
  (I3), each in-place image carrying its `[Image N]` label (issue #195
  F3 — the model can cite what it sees); the per-request cap
  (`images.maxPerRequest`, default 20) drops current-first-then-newest
  with a drop notice (never silent; the app logs drops via `AppLog`,
  issue #195 F4); dangling refs (compaction, cap) resolve to `(image no
  longer available)`, and once a renumbering boundary exists (compaction
  summary, structured marker, local-trim note) AUTHORED history
  citations degrade to that note too — after renumbering an `[Image N]`
  may name a different image, so silent rebinding is never allowed
  (issue #195 F2; generated refs/labels stay content-keyed and fresh).
  gh-1934 (413-proof sessions): image blocks OUTSIDE the kept region —
  first seen before the LAST renumbering boundary — evict to
  `[image dropped: <key8>]` placeholders (payload-only, JSONL
  byte-identical); kept-region images ride on under the normal caps; the 413 recovery ladder
  (`agent_loop_image_recovery.dart` + `image_recovery.dart`, bounded at
  2 passes per response, each 413 halving the session's adaptive
  `images.maxBytesPerRequest`) drops the oldest images (pass 1), then
  strips ALL images including the current message (pass 2, latched
  session-wide), carrying the `[images] recovered from 413:` notice +
  model-visible note; classification lives in `image_overflow.dart`
  (`isPayloadTooLargeError`), surface wording in `image_drop_ux.dart`
  (`ImageDropReason.evicted`).
  Stateless per-request rebuild — determinism, compaction eviction and
  resume come free. Kill switch `images.registry: false` → byte-for-byte
  legacy shape (no eviction, no ladder). `agent_loop.dart` applies it in
  `_buildRequestContext` after `transformContext`, before tool-pairing
  repair.
- `lib/src/trajectory/` — the trajectory ledger core (issue #10): finalized
  session records project into an immutable `TrajectorySnapshot` through
  `TrajectorySnapshotBuilder.append`/`applyEvent` — streamed agent events
  land as synthetic rows keyed `turn\0step` (`u\0turn` for prompts) and are
  replaced when the real record lands; revision grows per append. Record
  kinds (closed set, `TrajectoryCellKind`): system, user, context,
  compacted, message, tool, subtool — a subtool is a
  `TrajectoryToolRecord.parentCallId != null`, which only hosts build
  directly (the builder never nests). Derived state folds once per
  snapshot: `deriveTrajectoryLayout` (turns of Message/Step groups +
  collapsible turn/assistant-run summaries), `deriveTrajectoryTimeline`
  (four modes — `sequence` equal-width slots, `duration` with idle gaps
  compressed out, `time` zero-width wall-clock markers, `actual` real gaps;
  three fixed lanes: 0 system/user/context, 1 message/compacted, 2 tools),
  `trajectoryTimelineFocusIndexes` (selection → visible ledger indexes),
  and `ThrottledTrajectorySearchIndex` (full-text; matches are stable
  record ids). `formatters.dart` holds the shared duration/token/throughput
  formatting; `trajectory_preview.dart` the bounded single-line previews;
  `trajectory_export.dart` the whole-snapshot JSON/Markdown exporters the
  header's copy menu uses. Tool records carry `startedAt` (real launch
  time, distinct from the projected position) so the Gantt/actual
  projections plot true spans. Outbound model requests persist for the
  ledger as hidden `model_request_summary` `CustomRecord`s — the CLI
  event handler (`agent_event_handler.dart`, emitted through
  `agent_cli.dart`) and the app's `AgentService` both buffer a
  `TrajectoryRequestDetail` per call and flush it onto the session
  record chain right before the assistant message, so replays see it
  ahead of the reply — and `TrajectorySnapshotBuilder` folds them into
  the message record's request detail (the Request tab).
  Consumers render, never re-derive: `packages/fa_ui`'s
  `lib/src/trajectory/` widgets and the CLI `/trajectory` family.
- `lib/src/agent/finalize_gate.dart` — the FinalizeGate contract +
  TaskLedger (gh-1412): near-miss elimination for unattended runs. In
  unattended/bench mode the CLI system prompt appends the `finalize_gate`
  contract (`prompts/cli/finalize_gate.md`, composed in
  `agent_cli_prompt.dart`; interactive modes never carry it) — before any
  final summary the agent re-quotes every explicit requirement as a
  checklist, verifies each item with a real command against the produced
  state, and fixes every unmet item. The clock is the harness's
  (gh-1646): the contract says work to the wall — the time-left notices
  report the remaining budget, and while work remains the next
  compliant action is another approach, not a final answer (the run is
  interrupted automatically at the deadline). Feasibility is checked at
  commitment time (gh-1670): before any cost-dominating step (from-source
  builds, large downloads, brute-force searches) the contract teaches
  estimating the duration against the time-left notices and switching to
  a cheaper satisfying strategy — or, when none fits, the next-best
  partial — rather than gambling the window on a known-infeasible path.
  Conformance claims are the self-certification blind spot (gh-1834):
  when the final claim includes parity/conformance to a reference or
  specification (any domain), a "verified" item counts only with
  negative and combination checks — refused incompatible options,
  empty/corrupt inputs, boundary values, must-NOT-work cases — alongside
  happy paths; a blanket "everything matches" is not verified (prompt
  step 2.6, conditional: tasks with no conformance claim are
  unchanged).
  The loop parses
  the final answer's `task-ledger` fenced block (`parseTaskLedger`,
  last block wins) and emits `TaskLedgerEvent`; hosts persist the hidden
  `task_ledger` custom record (CLI: `agent_event_handler.dart` →
  `_onTaskLedger` in `trajectory_commands.dart` — the `appendCustomEntry`
  lives there, redacted through the host pipeline — wired through
  `handleAgentEvent`'s nullable `onTaskLedger` callback; unset keeps
  interactive sessions ledger-less), the wire protocol carries `task_ledger`
  (golden fixture +
  web client `KNOWN_EVENT_KINDS`), and `TrajectorySnapshotBuilder` folds
  the latest ledger into `snapshot.taskLedger` (legacy sessions degrade to
  null). The bench summaries render near-miss proximity from the synced
  session logs: terminal-bench adds a per-task `checklist` table column,
  harbor a `Checklist coverage` block — both parse the LAST `task_ledger`
  record (`pass`/`fixed` count as verified; no ledger → `checklist: none`).
  AC5: a declined `request_secret` in unattended mode carries the
  credential-hunt nudge (`credentialHuntNudge`;
  `AgentCoreServices.isUnattended`, keyed by the CLI on the LIVE approval
  mode so a runtime `/approval` switch flips it).
- `lib/src/cli/trajectory_commands.dart` (a `part of` `agent_cli.dart`) +
  `lib/src/cli/trajectory_tui.dart` — the read-only REPL family
  `/trajectory [view|cost|tail|inspect <n>]` (bare = `view`, capped at 200
  rows; `tail` follows the live session every 500ms) and the headless
  `fa trajectory <view|tail|cost|inspect> [sessionId] [--json] [--at N]`
  subcommand (`--at N` replays the snapshot as it stood at record N, view
  only). Session resolution: exact id > session-name match > most recent.
  Rendering is pure Dart in `trajectory_tui.dart` (no `dart:io`), shared by
  both entries; `bin/fah.dart` routes the subcommand.
- `lib/src/redact/` — layered secret redaction (issue #24): ten pure layer
  functions (registered/path/vendor/prefix/pem/asn1/connection/context/
  entropy/pii) merged priority-first into `RedactionPipeline.scan/redact`
  with `[REDACTED:<kind>]` idempotent markers, allowlist + data-URL
  pass-through, live-mutable `RedactionConfig`, and `RedactionStats`
  (per layer + per tool). `redaction_hooks.dart` attaches it to the agent:
  afterToolCall masks tool results BEFORE session persist, transformContext
  masks the outgoing context, beforeToolCall denies credential-file
  read/bash in `blockMode`, `redactPrompt` masks user input — write-side
  tools (`write`/`edit`/`checkpoint`/MCP write-ish) are never filtered
  (AC7). Config: `redact:` in `~/.fah/config.yaml` or project
  `.fah/config.yaml` (tolerant parse). CLI `/redact`; docs/redaction.md.
- `lib/src/hashline/` — hashline patch language: `[path#TAG]` headers
  (4-hex xxHash32 of whole file), `SWAP`/`DEL`/`INS.*` ops, all-or-nothing
  `HashlinePatcher`, stale tags reject before any write. Wired in
  `builtin_tools.dart`: `edit` takes `patch`, `read` takes `hashline` flag.
- `lib/src/tools/read_selector.dart` — `read` trailing selectors:
  `:N`/`:A-B`/`:A+C` (`..` alias), comma multi-ranges, `:raw`. A literal
  file named `x:1-2` wins over the selector. `offset`/`limit` must not be
  combined with a selector.
- `lib/src/tools/archive_reader.dart` — `read` inside archives
  (`a.zip:inner/entry`, `.tar`, `.tgz`), 256 MiB cap.
- `lib/src/tools/sqlite/` — `read` SQLite targets (`db.sqlite`,
  `:table[:key][?params]`, `?q=SELECT`). FFI engine (`package:sqlite3`)
  exported only from `lib/io.dart`, passed via `builtinTools(env, sqlite:)`;
  without it a clean "not supported" note.
- `lib/src/tools/shell_jobs.dart` — background shell jobs:
  `ShellJobRegistry` over the `BackgroundShell` capability
  (`execution_env.dart`; `LocalShell`/`LocalExecutionEnv` implement it,
  `SessionVarsExecutionEnv`/`SecretsExecutionEnv`/`MemoryExecutionEnv` and
  the app's `ProjectMountEnv`/`SandboxedExecutionEnv`/
  `PersistentWebExecutionEnv` forward it — the desktop app runs the host
  shell; mobile's `WasiSandboxShell` and web's `MemoryShell` run jobs as
  detached script Futures on job-local interpreter clones via
  `flutter_app/lib/sandbox/shell_job.dart` — own cwd/vars/capture, shared
  fs). `bash background: true` runs detached with output
  streaming into `.fah/bash_jobs/<id>.log`; `bash_job {status|output|stop}`
  (write tier) manages them. A settle fires `onSettled` on every exit —
  the CLI's terminal bookkeeping (`_onShellJobSettled`: job-board Running
  count, waiting row) hangs off it (issue #562). The model-facing notice
  (steered mid-run or a fresh idle turn; app `sendText` system-notice)
  is skipped when a foreground call consumed the result inline
  (`suppressSettleNotification`). gh-1835: a foreground bash call still
  running after `waiting.autoBackgroundSeconds` (default 60; 0 = kill
  switch) is auto-backgrounded — CONVERTED, never restarted (it already
  runs as a registry job under the soft-yield path): the pending tool call
  resolves exactly once with the backgrounded result (`bash_auto_background
  .dart` text, anchored on the hand-back sentence so the loop's stuck
  supervisor and budget ladder classify it as a real conversion), the
  settle notification stays armed, an explicit `timeout` at/below the
  threshold keeps the classic path while one above carries over as the
  job's cap, and hosts without `BackgroundShell` keep legacy behavior.
  Headless `fa -p` DRAINS live shell
  jobs after the final answer like in-flight subagents — the settles
  steer fresh reaction turns, loop (10 rounds) under ONE shared
  wall-clock ceiling `headless.shellJobDrainMs` (default 30 min; 0 =
  shell-job-scoped kill switch: live shell jobs detach at once while the
  pre-existing subagent drain stays unconditional), then the detach
  summary applies (gh-1459). The drain wrap-up also raises the
  settle→reaction fence: from `_finishHeadlessDrain` on, a job settle (or
  task completion) does bookkeeping only — no reaction run (gh-1589 I2).
  While the drain waits, every `headless.shellJobQuietMs`
  (default 5 min; 0 = off) of a still-running awaited job steers ONE
  interim liveness notice (`job <id> running · <elapsed> · tail: …` +
  the bash_job escape hatch), skipped for a crossing the model probed
  itself (`bash_job status/output` bumps the entry's probe generation)
  (gh-1459 ask #4). The headless `finally` then closes the session with
  the SEAL (`Session.seal`, gh-1589): after the usage fold + the
  job-board/obligations/subagent flushes (close order: drain → usage
  fold → seal → exit, the REPL teardown seals the same way), every writer
  observes the sealed session — late appends are DROPPED with one stderr
  warning per writer class, never written, so the session JSONL is a
  sealed artifact before the process exits. The seal is per-run state
  (a resume opens the same file unsealed); the harbor adapter mirrors the
  contract from the outside: `run()` returns only after the fa process
  exited (kill + bounded reap on every path, incl. external cancel; loud
  degradation when the reap times out). Job logs on disk are NOT
  secret-redacted.
- `lib/src/tools/availability.dart` + `availability_gate.dart` —
  capability-gated tool availability (issue #19): `resolveToolAvailability`
  merges the `tools:` scope stack (global `~/.fah/config.yaml` < project
  `.fah/config.yaml` < session `.tools/<sessionId>.yaml` < runtime
  `--tools`/`FA_TOOLS`; deepest scope wins per key) over the host's hard
  capability floor — absent tools can never be force-enabled, unknown ids
  warn. The gate applies a resolution to the live registry idempotently
  (hide/restore + prompt rebuild) and tombstones calls to disabled tools.
  CLI surface in `lib/src/cli/agent_cli_tools.dart` (`/tools`, live
  rebuild); docs/tool-availability.md is the user-facing page.
- `lib/src/tools/load_modes.dart` + `discover_tools_tool.dart` — agent
  load modes (issue #680): `--omp` > `FA_AGENT_MODE` > `agent.mode`
  (`default|pi|omp`) pick the tool-LOAD preset — `default` loads every
  enabled tool; `pi` the 4-tool benchmark base (issue #679, discovery
  off); `omp` the essential base with everything else discoverable,
  mounted on demand through the omp-only `discover_tools` meta tool (an
  explicit `tools: {id: on}` is a standing mount). The gate's
  `discoveryEnabled` flag keeps the discoverable tombstone from
  dead-ending on `discover_tools` in modes that don't register it. CLI
  sync + `/settings` switch in `agent_cli_tools.dart`/`settings_flow.dart`;
  user-facing docs: docs/tool-availability.md §Load modes.
- `lib/src/lsp/` — `lsp` tool (diagnostics/definition/references/rename):
  pure-Dart JSON-RPC client over `LspTransport`; `.dart` →
  `dart language-server --protocol=lsp`, projects merge `.fah/lsp.json`;
  lazy start, 5-min idle shutdown, crash respawn with backoff; renames apply
  all-or-nothing through the env. IO transport only via `lib/io.dart` +
  `builtinTools(env, lsp:)`; 1-indexed line/character; missing server =
  clean note, never a crash.
- `lib/src/mcp/` — MCP (Model Context Protocol) servers from the `mcp:`
  section of `~/.fah/config.yaml` (strict `ConfigException` parsing; config
  file only, no CLI commands). Stdio (`command`/`args`/`env`,
  newline-delimited JSON-RPC — NOT LSP's Content-Length framing) and remote
  (`url`, streamable-http default or legacy sse, `headers`). Message-level
  `McpTransport`; stdio framing glue is pure Dart over `McpByteChannel`
  (process impl only via `lib/io.dart`), both HTTP transports are pure Dart
  over injectable `package:http` (web gets remote servers; stdio = clean
  "not supported" status). `McpManager` connects lazily in the background
  (boot never blocks), per-server connecting/connected/failed status,
  reconnect with capped backoff; tools register as `mcp__<server>__<tool>`
  (exec approval tier, description prefixed with the origin, inputSchema
  verbatim) through the manager's `onChanged` (AgentCli re-registers +
  rebuilds the prompt's tiny MCP section). Results map MCP content blocks
  onto ours (text as-is, images as ImageContent, resources/links as text
  placeholders) under a shared 100k-char budget; `isError` throws so the
  loop records an error result; timeouts name `mcp.toolCallTimeoutMs`.
  Wired via `builtinTools(env, mcp:)`; resources/prompts out of scope.
- `lib/src/model_roles/` — model roles (`default`/`smol`/`slow`/`plan`) with
  fallback chains, key rotation (`ApiKeyRing` over `NAME`/`NAME_2`/…), 429
  mid-turn take-over (`FallbackStreamFunction`, never silent). Provider
  streams carry watchdogs (`provider_common.dart`:
  `providerConnectTimeout` 180s for the request, `providerStreamIdleTimeout`
  5min between bytes — overridable via the `providerTimeouts:` config
  section, `connectTimeoutMs`/`streamIdleTimeoutMs`, published to
  `providerTimeoutsOverride` at startup) so a wedged endpoint errors out — and the resolver
  can fail over — instead of hanging the turn forever. Streaming adapters
  share ONE keep-alive `http.Client` (`sharedProviderHttpClient`) instead of
  a fresh client per call: per-turn TCP churn piled TIME_WAIT sockets into
  connect stalls. Config:
  `roles:`/`modelOverrides:`/`retry:` in `~/.fah/config.yaml` (invalid
  schema = `ConfigException`). Also the shared models config:
  `media_model_slots.dart` (media slot names/fields shared with the app's
  `MediaModelsStore` + strict yaml slot entry) and `models_config.dart`
  (the `models:` section — per-slot media overrides + named custom model
  definitions `/model <name>` resolves; mutable like the custom-provider
  registry, persisted by the host). Owner context override (issues
  #273/#729): `agent:`/`contextWindowCap` in `~/.fah/config.yaml` (strict
  section, minimum 16384 = the compaction reserve) SETS the EFFECTIVE
  context window via `effectiveContextWindow` (model.dart) for the
  compaction thresholds, the CLI ctx meter/footer and the loop's over-window
  guard — clamped down below the catalog window; raised above it to the
  served truth (a custom provider whose catalog entry under-reports, e.g. a
  glm endpoint serving ~1M under a 200k catalog id). Uncapped runs are
  byte-identical. Threaded: CliConfig → AgentCliConfig (bin/fah.dart) →
  Agent → AgentLoopConfig. Compaction payloads (#729): every summarization
  request is bounded to `summarizationPayloadBudget(summarizerWindow)` —
  chunked summarization (chunk → `<previous-checkpoint>`/`<folded-checkpoint>`
  fold) when the dropped region exceeds it, explicit truncation note for a
  single oversized message; the smol summarizer's own window governs (never
  the main model's); overflow-classified compaction failures route straight
  to the next summarizer/local trim with zero backoff retries. Stall
  surface (gh-1395): a stream the idle watchdog kills is NAMED
  (`stall_taxonomy.dart`: connect / first-byte / mid-stream idle), traced
  under `FA_CONN_DEBUG=1` (`conn_trace.dart`: `conn open (fresh, port P)`
  → `first byte after Ns` → `idle watchdog FIRED after Ns (conn age,
  port P)` on stderr + the structured `connTraceEvents` board/sink the
  bench consumes), captured (`stall_sentinel.dart`: the outbound payload
  dumps to the trial dir before the abort; `scripts/replay_hang.sh`
  replays it byte-identically), and recovered with bounded cost
  (`silent_stream_policy.dart`: codex-style backoff 5→60s, `ApiKeyRing`
  rotation after the 2nd stall of the run, smol-role takeover attempt
  after the 3rd, counter reset on success — wired into every
  `ModelRolesResolver` chain entry, pre-commit stalls only, #964 kept).
  Purity split (gh-1395 review round 1): the four provider-forensics
  contracts are pure Dart and barrel-exported; every platform surface
  (env-knob lookup, the `[conn-trace]` stderr lines, the observed dart:io
  client, the sentinel's disk sink) is an injected seam installed at the
  host boundary by `installProviderStallForensics()` from
  `conn_trace_io.dart`/`stall_sentinel_io.dart` — reachable ONLY through
  `lib/io.dart`. Dumps are allowlist-redacted (credential carriers —
  `x-goog-api-key`, custom `authHeader` names included — never reach
  meta.json; only `safeForensicHeaders` survive) and carry a real SHA-256;
  the dump budget is 8 per process, `FA_STALL_SENTINEL=0` opts out.
  The shared client also carries `resetSharedProviderHttpClient()` behind
  the `FA_POOL_EVICTION` flag — pool hygiene, not a correctness fix (the
  keep-alive pool is test-exonerated for every watchdog-window class).
- `lib/src/ttsr/` — time-traveling stream rules: regex matched against
  streaming deltas; on match abort, inject rule bodies as hidden
  `<system-interrupt>` message, retry after 50ms. Persisted via
  `TtsrSessionSink`; guards: once-per-session, `maxInjectionsPerTurn`.
  Config: `ttsr:` in `~/.fah/config.yaml` + project `.fah/rules.yaml`.
- `lib/src/skills/skills.dart` — agent skills: `<root>/<name>/SKILL.md` plus
  Claude/Copilot/Codex layouts (`.claude/skills` + `.claude/commands`,
  `.github/skills`, `.codex/skills`, user-level equivalents incl.
  `~/.copilot/skills`), each root tagged with a `SkillSource`; project >
  user, first-name-wins. The package also ships first-party built-ins
  (`create-goal`, `self-settings`) compiled from
  `prompts/skills/<name>/SKILL.md` by `scripts/gen_prompts.dart` into
  `builtin_skills.dart` — merged into discovery LAST (a same-named
  project/user/granted skill shadows the built-in), never gated by the
  skills-access consent, served to `read` from virtual
  `builtin://skills/<name>/SKILL.md` paths. Per-skill on/off toggles
  (`skill_availability.dart`: `skills: {<name>: on|off}`, global
  `~/.fah/config.yaml` < project `.fah/config.yaml`, deepest mention
  wins) gate the prompt/completion/invocation surfaces live via
  `/skills on|off <name> [global|project]` and the `/settings` Skills
  row. Third-party roots are discovered BY DEFAULT
  (opt-out): `skills_access.dart` `SkillsAccess` ask/granted/denied with
  `granted` as the zero-config default — `allowedSources` on
  `discoverSkills`/`discoverTaskAgents`; CLI `skills:` config section,
  the TUI `/skills` management menu + `/skills access`, startup dialog
  only for an explicit `ask`; app `SkillsAccessStore` + settings/boot
  dialog). Typed frontmatter lives in
  `skill_manifest.dart` (`SkillManifest` — allowed-tools, context: fork,
  paths, user/model-invocable …; unknown keys = notes). Only metadata
  enters the system prompt (path-gated `paths:` skills appear once a
  matching file was touched); bodies loaded with `read` or rendered for
  invocation by `skill_renderer.dart` (`$ARGUMENTS`/`$N`/`${CLAUDE_*}`,
  `` !`cmd` `` shell injections through the env, `allowed-tools` →
  per-turn approval grants, `context: fork` → the task tool). Migration
  guide: `docs/migrating-from-claude-copilot-codex.md`.
- `lib/src/prompts/project_context.dart` — `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`/
  `GOAL.md`/`DESIGN.md` plus per-directory GitHub Copilot files
  (`.github/copilot-instructions.md` and `.github/instructions/
  *.instructions.md` — `applyTo` globs not evaluated, scoped files get an
  `<!-- applies to: ... -->` marker, `excludeAgent` ignored) auto-merged into
  the system prompt: cwd → git root, farthest-first, `<!-- From: -->`
  annotations, 32 KiB leaf-first budget; optional `~/.fah/AGENTS.md` first.
  CLI: `/skill:<name> [args]`, the `/<name>` alias, `/skills` (TUI: a
  management menu — picking a skill prefills `/skill:<name> ` into the
  composer via `FaTuiController.sendInputText`, plus access/import rows;
  line mode: plain list) with `[reload|access [ask|granted|denied]|import]`
  subcommands (bare `/skills access` opens an interactive picker, run
  detached from the sequential line REPL like the guided provider flows).
- `lib/src/task/` — `task` tool: parallel subagents, batch form
  `{context, tasks[]}` + `background` flag; children never get `task` (no
  nesting); roles: `explore`→`smol`, `review`→`slow`, `plan`→`plan` — a
  role resolves through the roles resolver only when explicitly pinned
  (`ModelRolesConfig.pinsRole`); an unpinned role keeps the parent's live
  wiring, so the child inherits the parent's runtime-resolved output cap
  instead of the default chain's rebuilt catalog default (issue #302);
  `outputSchema` with
  ONE fix retry; child failure = per-item error, never batch failure.
  Agent types: built-ins (`task`/`explore`/`review`/`plan`) plus discovered
  `.md`/`.agent.md` files (`agent_discovery.dart` — roots `.fah/agents`,
  `.agents/agents`, `.claude/agents`, `.github/agents`, `.codex/agents` +
  user-level, gated by the skills access setting; `canonicalTaskAgentName` folds
  Claude/Copilot names like `general-purpose`/`Explore`/`Reviewer` onto the
  built-ins).
  `/tasks` lists jobs (background agents AND background shell jobs),
  `/tasks cancel <id>` routes by id; completions re-enter the parent
  as async-result messages (`agent://<id>` refs). Subagents are retained &
  addressable: real JSONL child sessions, `task_status`/`task_observe`/
  `task_send`/`task_cancel` (model-facing job abort), child-only `reply` +
  sibling `agent_message` (pending-queue + hop-capped),
  `completed_without_reply` notice. gh-1951 (deliverable guarantee): the
  explicit reply rides BOTH parent-visible renders verbatim when in
  budget (`_renderResultBody` — the #1829 envelope when over); the
  `completed_without_reply` notice actually renders when no reply was
  recorded; the `reply` ack is truthful (`ReplyRecordOutcome` — a missing
  handle or a duplicate reply is an error/`duplicateNoted` result, never
  a false "delivered"; the ack waits out `persistNow`), double reply is
  idempotent (first wins), `task_observe` echoes the deliverable payload
  (`childMessageText`, bounded at the report budget), and a resumed
  child's completion is PUBLISHED through the same
  `TaskJobManager.completions` async-result envelope every host consumes
  (`TaskExecutor.resultPublisher` → `publishResumed`): the resumed final
  answer replaces the stored `agent://<id>` output, and a reply acked in
  a killed previous life is carried onto the resume as a resolvable
  artifact (`peekPendingReply` → `DeliverableCapture.persistCarriedReply`
  → `clearPendingReply` — the handle clears only after the artifact is
  durable, so a failed carry leaves the reply resumable)
  — never silence. gh-1948: the executor flushes each
  child's transcript at every turn boundary (the JSONL exists and grows
  mid-run), and `task_observe` resolves a placeholder-handle child
  (`<parentSessionId>/<id>` until the first flush) through
  `resolveChildSessionPath` (`child_session_io.dart` — the sessions-tree
  header scan) wired by the CLI via `SubagentServices.resolveChildSessionPath`,
  healing the handle onto the real path; read failures degrade to a
  structured "no transcript available yet"/"transcript unavailable"
  message, never an uncaught exception. Child IDENTITY for tool calls is
  zone-scoped (`subagent_scope.dart`, gh-970): `runSpawn`/`resumeChild`
  publish the running child's id via `runWithSubagentScope`, and
  `TaskExecutor.currentSubagentId` reads the zone FIRST — the executor's
  in-flight id stack is shared by all concurrent children, so its head is
  "started last", not "executing" (that shift mislabeled every sender
  envelope and recorded replies on sibling handles). Hosts also resolve
  shared tools' self-mailbox semantics through the zone (`activeSubagentId`
  → `schedule_message`'s `senderMailbox`), and the CLI wires
  `SubagentManager.wakeChild` so mail that fires into a finished child's
  inbox (a self-scheduled reminder, sibling mail) resumes it in its own
  session — the child-side analog of the idle inbox wake (the sweep is
  `wakeChildrenWithPendingMail`, status-gated to completed/idle, one wake
  per child per settle, a throwing wake retires the child).
- Steer soft-yield: a steering message (user `Ctrl+S`, subagent completion,
  inbox mail) arriving DURING a tool-call phase cancels the phase's
  zone-scoped yield token — `currentYieldToken()` in `cancel_token.dart`,
  published by `_runToolCallPhase` (`agent_loop.dart`), fed by
  `AgentLoopConfig.steeringNotifications` (in-process queue) and the
  non-draining `hasPendingSteering` probe (external inbox, 2s poll).
  Yield-aware tools (`bash`, blocking `task`) finish the tool call early
  WITHOUT stopping the work — it continues as a background job and the user
  message is delivered at the step boundary. Tools ignoring the token keep
  the classic behavior (message waits for the phase).
- `lib/src/messaging/` — the agent messaging fabric: every agent (main,
  subagents, other Fa instances sharing the root) owns a file inbox behind
  the isolated `MessagingRepository` interface (send/peek/drain/directory —
  future DB/network impls drop in without caller changes).
  `AgentMessage.kind` distinguishes agent chat from `user` input handed
  over by an attached client (the Fa app's attach view; the CLI delivers
  it as `[from app] …`, its own words, not agent chat).
  `FileMessagingRepository` over `ExecutionEnv`:
  `<root>/<agent>/inbox|read/<id>.json`, timestamp-ordered names, sanitized
  agent dirs, torn writes skipped. `SubagentManager.messaging` routes
  `enqueueMessage`/`drainMessages` through the fabric (in-memory queue is
  the no-fabric fallback); `mailboxPrefix` (the session id, set by the host
  on every session init/switch) namespaces mailboxes so two instances never
  drain each other — ids with `/` are absolute cross-instance addresses
  (`<sessionId>/main`). Sessions also carry their display NAME
  (`--session goal_builder`): `register(agentId, {sessionName})` persists
  it in a `.name` marker + messages-registry.json, `agent_directory`
  renders `name (id)`, and `agent_message` resolves `goal_builder` /
  `goal_builder/main` through the directory (exact ids/siblings/`main`
  pass through untouched; ambiguous names error with candidates).
  `agent_message` targets siblings, `main`, a session name, or an
  absolute mailbox; `agent_directory` lists LIVE fabric mailboxes (recent
  activity via the heartbeat hosts touch on their inbox-watch timers) plus
  anything with pending mail — stale mailboxes from finished sessions are
  hidden behind the tool's `all: true` (`.id` markers keep real ids despite
  dir sanitization; `_scheduled`/dot-dirs are not mailboxes).
  `schedule_message` (issue #59): records under `<messagesRoot>/_scheduled/`;
  self-addressed records deliver to the host's LIVE mailbox at fire time
  (the address pinned at schedule time goes stale on session switch/restart
  and would strand the reminder) — EXCEPT self-addressed records naming a
  subagent mailbox of this session (`<prefix>/<childId>`, gh-970): those
  deliver as recorded (the address rides the same owner prefix and is as
  stable; re-addressing stole the child's reminder into main), and the
  tool's `senderMailbox` override (host-wired from `activeSubagentId()`)
  makes a subagent's no-`to` schedule default to the CHILD's mailbox, not
  main's — hosts re-arm on every mailbox change
  (CLI `_syncMailboxPrefix`, app `_setMailboxPrefix`) and sweep due records
  on their inbox ticks; `dispose()` cancels only the timer, the files stay.
  gh-1180: a re-addressed SELF record also delivers FROM the live mailbox
  (`from` rewritten alongside `to` in `_deliverDueInner`) — an adopted
  reminder keeps the self shape (from == to) the wake policy needs to
  classify it exempt, so a chain survives a session-id change. Every
  lifecycle step lands in the receipt trail
  (`<messagesRoot>/_scheduled/receipts.jsonl`, `ScheduledReceiptLog`,
  best-effort): scheduled / delivered / delivery_failed / scan_failed
  (queue) and wake_attempted / turn_started / wake_refused (both hosts'
  wake paths; refusal receipts are once per refusal EPISODE — the latch
  lives in `InboxWakePolicy` next to the streak, so a held gate cannot
  spam the trail and a repeat episode after user input is receipted
  again).
  Sleep resilience (issue #259): all due math rides an injectable wall
  clock (`ScheduledMessageQueue(clock:)`), long waits are split into ≤60s
  timer legs (`maxTimerLeg`) that recompute the remaining delay from the
  wall clock on every fire — never accumulating duration drift — and
  hosts run a catch-up sweep at every TURN START (CLI `_beginUserPrompt`,
  app `sendText`) in addition to the idle inbox ticks, so the first
  post-sleep turn delivers every overdue record immediately. Catch-up is
  exactly-once per record (file removed on send + the `_delivering`
  in-flight guard) — missed cycles of a recurring self-re-arm are NOT
  replayed; the re-armed cycle simply resumes from "now". For true
  sleep-proofing (delivery DURING lid sleep) no in-process timer can
  help: add an external pinger, e.g. a cron/launchd entry that messages
  the session's mailbox — mail to an asleep session already launches a
  headless wake run that drains the inbox and sweeps due records.
 Failure isolation (issue #270): a throwing `send` is contained per
 record (logged via `onError` — CLI `[sched]` line, app `AppLog`), the
 record stays for the next sweep, and the post-failure re-arm floors the
 leg at `failureBackoff` (60s) so a poison record cannot spin a
 zero-delay timer; sweeps deliver in due-time order, and the app's
 turn-start sweep is awaited so the fresh turn sees the fired reminder.
 A failed SCAN (transient `listDir`/read error on a leg, gh-1180) is
 equally loud: `onError` + a `scan_failed` receipt, then a re-arm at
 `failureBackoff` — the arming heartbeat never silently disarms
 ("scan failed" used to be treated as "nothing pending", permanently
 disarming the scheduler with zero log). Corrupt record CONTENT is
 still skipped, not fatal (issue #59). Every lifecycle step is
 receipted to an append-only JSONL trail at
 `<messagesRoot>/_scheduled/receipts.jsonl` (`ScheduledReceiptLog`,
 gh-1180): `scheduled` / `delivered` (with lag) / `delivery_failed` /
 `scan_failed` from the queue, plus host-side `wake_attempted` /
 `turn_started` / `wake_refused` (with reason) from the CLI wake path —
 a post-mortem can distinguish "timer never fired" (no `delivered`)
 from "wake refused" without reading source. The trail is best-effort:
 a failing write logs via `onError` and never breaks scheduling.
 Records carry the scheduling instance's `owner` (mailbox prefix): a
 sweeper re-addresses a self-addressed record only when the stored owner
 matches its own prefix, and never deletes another instance's record -
 foreign-owned records are left where their owner sweeps (also across a
 root change: only own records migrate to an adopted folder's root).
 Legacy untagged records drain via the old any-sweeper path; records
 whose owner session is deleted (`/reset` mints a new id) stay on disk -
 there is no reaper, cleanup is manual. `agent_fabric` resolves the
 messages root lazily per sweep (was: pinned to the launch cwd at
 construction), and pending records migrate across a root change, so a
 session-folder adoption carries the reminders along instead of
 stranding them under the launch cwd.


  The `## Agent messaging` prompt section (prompts messaging_section.md, CLI +
  app variants) tells the model its own mailbox address. Turn-boundary
  delivery: `Agent.externalSteeringSource`
  merges inbox drains into the steering poll (main in AgentCli/AgentService
  as `_mainInboxMessages`, children via the executor) — messages land as
  sender-attributed user messages, so they persist in the session and read
  like a chat. Idle wake: an inbox watcher (2s CLI / 3s app) starts a turn
  when mail arrives while idle — two Fa instances chat live; a 10-run
  streak cap without user input breaks agent-to-agent ping-pong loops.
  The lanes live in `InboxWakePolicy` (gh-1180): user-kind mail always
  wakes and resets the streak (gating it would deadlock:
  no run → no reset → no run); a delivered `schedule_message`
  self-reminder (`[scheduled] ` prefix, from == to) is EXEMPT from the
  cap — a deliberate agent-chosen cadence (night watch, periodic sweep)
  wakes forever, with a 30s cadence floor so a zero-delay re-schedule
  spin is still bounded like chatter; foreign agent chatter stays
  capped. A refused wake is never silent: one dim `[mail] wake refused`
  line per episode and a `wake_refused` receipt.
  UI: `/agents` rows show a `mail:N` pending marker (the CLI
  font has no ✉ glyph), the app's AgentsSection shows `✉N`; observe/detail
  views list the pending inbox.
  Issue #27 adds the hub-first composition: with `DAP_MASTER_SECRET` set
  and the hub plugin enabled, `bin/fah.dart` wraps the hub as
  `HubFabricRepository` (bin/, IO-bound) and routes the fabric through
  `FallbackMessagingRepository` (lib) — hub-first for hub-resolvable
  targets, file inboxes as offline fallback, queued mail forwarded on
  reconnect, merged drains deduped by id. `AgentCliConfig.hubFabric`
  hosts inject it; the plugin host skips its separate inbox when the
  fabric owns delivery (one hub-mail consumer). Subagent drains never
  touch the hub. Issue #304 adds the one-step CLI surface over it:
  `fa dap start|stop|status` (bin/fah_dap_command.dart —
  `DapHubController`, every IO a seam) probes the port (`/healthz` + a
  `/ws` presence handshake; foreign server = clear error naming the
  port, no enrollment), spawns `fa hub serve` detached, prompts the
  master key ONCE (hidden; empty = open hub, the zero-config extension
  default; non-interactive starts prompt nothing), enrolls per the
  DAP_MASTER_SECRET flow and persists only the hub-issued clientSecret
  (0600 `~/.dap/config.json`; wrong key re-prompts 3x then a manual
  hint — a rejected secret is never persisted). The hub pid/state file
  `~/.dap/hub.pid` (parse in lib/src/hub/dap_local_hub_state.dart) lets
  a second CLI attach (no double-spawn) and `fa dap stop` work from ANY
  instance exactly once — stop names connected peers (e.g. "Browser")
  and SIGTERMs the owning pid; the fabric falls back to file inboxes.
  The `/dap` menu's leading row is state-dependent (AC7): "Start DAP
  locally (one step)" stopped, "Stop DAP" running
  (lib/src/cli/dap_menu_options.dart `dapMenuOptions(hubRunning:)`).
  `agent_directory` renders hub roster entries (MailboxEntry.source ==
  'hub') with a `[hub]` marker; the `fabric.hub: false` kill switch
  (FabricConfig.hub, gate `hubFabricWired` in bin/hub_fabric_
  repository.dart, mirrors images.registry) leaves the fabric the bare
  file layer — byte-identical legacy listing (REG test
  test/messaging/fabric_kill_switch_reg_test.dart).
  Issue #27 phase 3 adds the A2A boundary gateway: `agent_message` accepts
  `name@machine` for OTHER machines — `A2aMailGateway` (lib/src/a2a/
  a2a_mail_gateway.dart) resolves the machine against the `a2a:` config
  section (the server named like the machine) and sends the mail as an A2A
  `message/send` with a `faMail` metadata envelope (id/from/to/text/sentAt/
  hops, sender address stamped `mailbox@machine` for replies); a failed
  remote task errors instead of dead-dropping. Inbound: `fa serve --a2a`
  mounts a mail sink — envelope-carrying sends deposit into the project's
  file inboxes (resolved by mailbox id or session display name) instead of
  running a turn; endpoints without a sink fail such sends honestly. The
  hub stays the intra-machine transport; A2A stays the interop boundary.
- `lib/src/session/attach/` — attached-session infrastructure (the Fa app
  watching a live `fa` CLI session 1:1 and handing it input): three
  INTERFACES so a later network impl (`fa serve --attach`, remote headless)
  drops in without touching consumers — `SessionPresenceStore`
  (register/touch/unregister/list; stale heartbeats auto-drop, crash
  coverage; gh-1660: `list()` also SWEEPS dead heartbeat files — a stale
  file is deleted when its pid probe reports the process dead
  (`probePidAlive` in lib/io.dart, wired by bin) or its age passes the
  5-min `cleanupAfter` grace, so `.presence/` stays bounded; live pids
  are never swept), `SessionEventSource.watch` (transcript tail as
  `AttachedMessage` rows: user/assistant/tool), `SessionInputChannel.send`
  (user input to the owning process). File impls:
  `FileSessionPresenceStore` (`<sessionsRoot>/.presence/<id>.json`,
  15s staleness) and `FileSessionEventSource` (JSONL tail via
  `readTextLines` deltas) + `FileSessionInputChannel` (fabric mail,
  `AgentMessageKind.user`, to `<sessionId>/main`). CLI wiring: `run()`
  registers presence, the 2s inbox timer touches it every other tick,
  `finally` unregisters; `AgentCliConfig.presenceStore` is injectable
  (bin/fah.dart builds the file store; tests inject fakes). Header-only
  session files (crashed runs) are swept fire-and-forget at every CLI
  boot — `_initializeSession` → `JsonlSessionRepo.cleanupEmptySessions`
  with a 10-min mtime grace so a concurrently booting process's
  brand-new file is never sweep food. CLI sessions
  carry `agent: cli` metadata (the app writes `fa`). App wiring:
  `CliSessionPresence` service (3s poll) + green-dot `live` on
  `SessionTile`; a live tap in the chat-sheet drawer opens
  `AttachedSessionScreen` (controller `attached_session_controller.dart`)
  instead of a second writer on the same JSONL.
- `lib/src/memory/` — long-term memory: `MemoryController` over the
  `flutter_agent_memory` package (hosted pub.dev dep),
  `execution_env_kb_storage` (KbStorage → ExecutionEnv), `memory_add`/
  `memory_search`/`memory_list` tools (`memoryTools(controller, onChanged:)`),
  and the `<memory>` prompt section: `formatPromptSection()` (BOTH scopes,
  entities parsed via `KBFileParser` — the raw file's first line is the
  `---` delimiter, not the fact) is cached by the host and recomposed into
  the system prompt asynchronously after startup + on every `memory_add`
  (CLI `_refreshMemorySection` in agent_cli.dart, app in AgentService);
  phase 2:
  `compaction_memory_hook` (compaction-time durable-fact extraction on the
  smol role, non-blocking), `maintain()` (levels + consolidate, running
  guard, 24h stamp), triggers on session start + `/memory maintain`;
  `/memory` shows stats.
- Git-backed memory (the repo IS the memory): storage paths come from the
  `memory:` config section — project `.fah/config.yaml` wins over
  `~/.fah/config.yaml` (`loadProjectMemoryConfig`); a relative
  `projectPath` resolves against the project root. This repo dogfoods it:
  `.fah/config.yaml` points at the COMMITTED `memory/` directory — clone
  the repo, get its memory. Inside the store dir: `MemoryRepoInit.
  ensureGitSupport()` (flutter_agent_memory 0.2.0) keeps `.gitignore`
  (derived artifacts: GRAPH.md, MEMORY.revision, INDEX.md,
  .last_maintenance — rebuilt on load, never committed) and
  `.gitattributes` (`DELETIONS.md merge=union` — the append-only
  tombstone ledger merges by union). Note ids are merge-friendly since
  0.2.0: `n_0447_a1b2` = sequential index + 4-hex md5 of the normalized
  text (parallel branches union-merge; legacy `n_0001` ids stay valid
  forever). The `memory_add` description IS the package's
  `MemoryPolicy.memoryAddPolicy` (docs/memory/memory_add_policy.md in
  the memory repo): durable facts only, solved problems are superseded
  via delete+add (never left to rot), project scope is PUBLIC (git) —
  no secrets/personal data there, user scope stays machine-local.
  `.gitignore` whitelists `.fah/config.yaml` (+rules/lsp/mcp/agents/
  skills/packages); logs/sessions/bash_jobs stay local. Commit memory/
  changes with the task that produced them (`memory:` prefix for
  memory-only commits).
- `lib/src/a2a/` — A2A (Agent2Agent) interop: `a2a_client.dart` (Agent Card
  + JSON-RPC + SSE), `a2a_config.dart` (`a2a:` yaml section, `${NAME}`
  env tokens), `a2a_manager.dart` (lazy per-server connect, A2A task state
  → subagent lifecycle mapping), `a2a_server.dart` (request handler).
  `task` tool agent type `a2a:<name>` runs remote agents as subagents
  (uniform `task_status`/`task_send`); `/a2a` shows server status;
  `fa serve --a2a [--port N] [--token T]` mounts this agent as an endpoint
  (`bin/serve_a2a.dart`).
- `lib/src/cli/hep.dart` + `agent_cli_hep_io.dart` — HEP v1, the Harness
  Event Protocol (`fa --output events[=full]`, issue #155): strict JSONL
  on stdout for server-side supervisors, one JSON object per line,
  flushed per line. A TURN is one assistant LLM ROUND, not one user
  message — a user turn that runs tools yields SEVERAL terminal frames
  (`turn_done` per round, ids incrementing). `HepWriter` is
  `AgentListener`-shaped (`agent.subscribe(hep.handleEvent)`); the
  `HepEventsIO` decorator (a `part of agent_cli.dart`) drops
  `CliIO.write` so stdout stays pure while diagnostics keep stderr.
  Frame catalog, ordering/flush guarantees and versioning policy:
  docs/hep.md; byte shape pinned by golden tests (test/cli/hep_test.dart).
  `--attach` sniffs image mimes by magic bytes (png/jpeg/gif/webp ride
  as base64 blocks); any other file passes through as an
  `[attached file: …]` path reference appended to the prompt (issue
  #196) — never an octet-stream image block.
- `bin/fah.dart` — the `fah`/`fa` CLI. REPL (no args) or headless
  (`fa "prompt"` / `-p` / `--prompt-file <path>` (alias `-f`), mutually
  exclusive). First positional naming an EXISTING file is the prompt source
  (`.md`/`.txt` inlined, others attached by reference; `-p` is verbatim;
  `--prompt-file` reads ANY path verbatim, missing/unreadable = usage
  error exit 64). Args parsed in `lib/src/cli/cli_args.dart`
  (pure Dart). Headless: exit 0/1/130; `CliIO` contract — `write` = primary
  stream, `writeln` = diagnostics (stderr headless). The TUI captures the
  mouse by default (wheel scrolling + click routing — the alternate screen
  has no native scrollback): SGR 1002+1006 with a per-frame hit-region
  registry (`tui_hit_regions.dart`, topmost-region click/drag/release
  routing in `fa_tui_mouse.dart` — composer caret on mousedown, model
  picker rows, queue-row drop); legacy X10 payloads (modes 9/1000) decode
  too; `/mouse off` degrades to keyboard with a one-time hint. Selection
  works via the terminal's bypass modifier (Shift), and `FA_TUI_MOUSE=0`
  (`AgentCliConfig.tuiMouseCapture`) hands the mouse back for always-on
  native select-to-copy.
  Shift+Enter's HID poll is resolved once at startup
  (`lib/src/cli/shift_hid.dart`, issue #355): disabled when
  `SSH_CONNECTION`/`SSH_TTY` is set, under `FA_TUI_SHIFT_HID=0`, or when
  the one-shot CoreGraphics probe (sacrificial isolate, ~300 ms timeout)
  hangs — the returned callback is null and a bare CR stays a submit.
- `lib/src/cli/` — REPL machinery: `/provider [name] [baseUrl] [token] |
  custom` (guided wizard in `provider_flow.dart` + `provider_commands.dart`;
  `/models` fetched for openai-like endpoints), custom providers in the
  `customProviders:` section of `~/.fah/config.yaml`. Editing a saved
  OAuth-connected entry (OpenRouter) offers the connect-time sign-in choice
  at the key step — keep / Browser OAuth re-auth / paste a key
  (`CustomProviderFlowConfig.reauth`). The same picker appears for
  CodeMie entries in edit mode (matched by the `/code-assistant-api/`
  URL marker — works for legacy entries whose `authMethod` was never
  recorded): `Browser SSO (CodeMie)` (`_mintCodeMieSsoCookie`); the
  wizard applies the minted value through format-aware switch routing
  (`isCodeMieJwtToken` decides SSO-cookie vs JWT-Bearer) so the cookie
  stays a `cookie:` header (not Bearer) and the JWT keeps its Bearer
  slot. Every add/connect flow that saves a
  registry entry offers a provider-name step (`_askConnectProviderName`:
  typed value, else the endpoint host; a clash with a DIFFERENT endpoint
  retries, and so does a name matching a CATALOG provider — `/provider
  kimi` routes to the catalog before the registry lookup, so such an
  entry would be unreachable) — the custom wizard, DIAL (custom names
  scope the store key; the switch stores under the entry's slot via
  `tokenKeyName`), Kimi (a typed key becomes a named
  entry with a name-scoped key; a resolved key offers "use it / add a
  second account"), OpenRouter OAuth + API-key, ChatGPT OAuth (lands a
  registry entry too, `apiType: chatgpt`; ONE identity per auth domain —
  issue #1706: a second codex/chatgpt auth lands ON the resolved
  same-domain record, a typed new name RENAMES it instead of minting a
  twin, and the load merge folds any codex records that already exist —
  so `/provider` lists the ChatGPT account exactly once, however it is
  named), CodeMie SSO/JWT (the
  SSO name step only from the explicit add flows: `offerName` — automatic
  re-authorizations on startup/switch/mid-stream expiry stay silent; a
  NEW account name re-runs the guided project → model pick, a re-login
  to the same entry keeps its model).
  Saved-entry lookups are by base URL (`_entryForBaseUrl`), so a renamed
  entry is not duplicated on re-connect. Catalog switches RESET
  `_activeCustomName` (kimi/openrouter stored-key branches included) —
  a leaked marker made `/model` rewrite the previous custom entry's
  model memory. `/models` also manages
  the `models:` section: `/models config`/`set <slot> <model> [baseUrl]`/
  `remove <slot>` for media slot overrides (persisted via
  `onModelsConfigChanged`), and `/model <name>` resolves `models.custom`
  definitions. Keys: env first, then
  secure store (`lib/src/secrets/secure_key_store*.dart` — Keychain /
  Secret Service / PasswordVault, IO backends only in `lib/io.dart`),
  preloaded into `SecureKeyCache`. Resolution: the spec's DEFAULT endpoint
  gets env → `FA_KEY_<HOST>` → `FA_KEY_<HOST>_<NAME>` → legacy; any other
  endpoint resolves ONLY its scoped store keys (env names never hijack a
  custom endpoint); `/key set` writes store-only, never config.
  `/settings` is the interactive settings hub: a TUI picker whose entries
  (Provider, Edit/delete provider, Chat model, Model capabilities, Media
  models, Agent models, Approval mode, Agent mode, API keys, MCP servers)
  launch the same flows the dedicated slash commands open; line mode prints
  a summary. ALL TUI pickers (generic host pickers included) have
  type-to-filter + backspace (generic ones filter their static item list
  locally via `menuAllItems`, the models picker rebuilds through
  `buildModelMenu`; a no-match filter keeps the title + `(no matches)`).
  The `/model` TUI menu is TWO-STEP when several providers exist:
  `_buildModelMenu` returns provider rows (`@<name>` keys, the filter
  matches provider names AND their model ids) first, and selecting one
  opens that provider's model list (generic `modelProvider` picker whose
  `provider|model` rows route back through `_tuiSelectModel`'s
  cross-provider switch). A single provider goes straight to its models.
  Model rows render as a TABLE (`buildModelPickerTable` in
  `model_picker_table.dart`): `● id  provider  ctx  cost` with the
  context window compacted (1048576 → `1M`) and `$/Mtok` from the catalog
  (`—` when pricing is unknown, never 0.00); rows sort recency → cheaper
  total → unpriced last; narrow widths elide cost first, then provider,
  keeping id + ctx. The rows are click targets (hit-region routing).
  The provider→model pick flows live in `lib/src/cli/settings_flow.dart` in the
  NAMED `SettingsFlow` extension (public `runProviderModelFlow`/
  `startChatModelFlow`/`startMediaSlotFlow`/`startAgentModelFlow`), so
  tests can drive them line-mode (see `test/cli/settings_flow_test.dart`).
  The model-list fetch dispatches per dialect
  (`_fetchProviderModelIds`: CodeMie `/llm_models` by URL marker, DIAL
  deployments when the spec is `dial`, the Codex backend `/models` for
  the chatgpt-codex kind — the same call codex-rs' models-manager makes,
  with the bundled synced catalog (`chatGptCodexModels`,
  `scripts/sync_codex_models.dart`) answering offline — else OpenAI
  `/models`; the saved entry's own key authenticates; failures fall back
  to manual entry; the `/model` picker's per-entry cache refresh
  (`_fetchIdsForProvider`) shares the same dispatch so a saved codex
  entry lists the whole catalog, not just its last-used model).
  `startAgentModelFlow` pins the `smol`/`subagent` role chains through
  `ModelRolesResolver.setRoleChain`/`clearRoleChain` (the resolver is
  created on demand when the config had no `roles:` section —
  `AgentCliConfig.modelRolesResolver` is mutable) and persists via
  `onModelsConfigChanged` (bin/fah.dart's persistConfig reads the live
  resolver config).
- `lib/src/cube/` — fa_cube sandbox profiles (issue #8): strict `CubeSpec`
  YAML (`.fah/cubes/<name>.yaml`, apiVersion fa/v1 kind Cube) with
  tool/network/fs/env/resource/cache policies (deny-wins, empty allowlist =
  deny-all, lexical path normalization as traversal guard), `CubeResolver`
  (path > name lookup), Dart-layer enforcement (`SandboxedExecutionEnv`
  decorator: `CubeFsGuard` gates the agent's own read/edit/write tools,
  `CubePolicyEngine` gates bash incl. pipes/`$(...)` subshells and shell
  redirect targets (`>`/`>>`/`<>`/`&>`/`2>` writes, `<` reads, `2>&1`
  exempt; arguments stay name-gated only), exit 127
  denials with per-exec reason), content-addressed `CubeCacheManager` under
  `.fah/cube-cache/<md5>/` (manifest + ttl). `spec.backend:` = `policy`
  (default, Dart-only) | `kernel` opt-in: every command wrapped in the OS
  sandbox via `CubeSandboxBackend.wrapCommand` — macOS `sandbox-exec -f
  <profile>`, Linux `unshare --user --map-root-user --mount [--net iff the
  spec allows no network]` + `ulimit -v/-t` ceilings, both over a clean
  `env -i` environment; profiles staged content-verified under
  `<home>/.fah/cube-profiles/<md5>.sb` (outside the guest-writable
  workspace; re-verified against the recomputed profile before every
  wrapped exec — #790); kernel mode fail-closes (`fa_cube[<name>]:`
  error, no exec) when the staging location is not provably
  guest-unwritable — a `homeDir` inside/relative-to the workspace or a
  spec mount granting rw over it (the refusal names
  `spec.allowDegrade: true` as the explicit policy-mode escape hatch;
  with it set, the bind degrades and `onDegrade` fires); the staging
  dir is swept once per
  binding for this profile's own `.tmp` orphans (other bindings' files
  untouched); the macOS SBPL profile denies writes blanket outside the
  workspace + `rw` mounts (`/dev/null`, `/dev/fd` exempt) and denies reads
  of `/etc` + user homes when no root mount grants reads (a blanket read
  deny would abort exec — dyld); Windows = Job Object descriptor only
  (kernel on a platform without an enforcing backend is REFUSED — clean
  `fa_cube[<name>]:` error naming `spec.allowDegrade`, zero commands —
  unless the spec opts in via `allowDegrade: true`, which degrades to
  policy mode with the loud `fa_cube[<name>]: kernel backend unavailable,
  running in policy mode` warning; `effectiveBackend` reports what
  actually ran — #793); a wrapper that is missing from
  PATH or refuses the sandbox (EPERM, SBPL
  rejection) surfaces as a clean `fa_cube[<name>]: kernel backend ...`
  spawn error in foreground execs and background jobs alike. CLI:
  startup precedence flags > project `.fah/config.yaml` `cube:` > user
  config (`resolveStartupCubeSource`), `/settings` Cube sandbox picker
  (shared switch logic in `agent_cli_cube.dart`, persists the `cube:`
  startup default), `/cube [use <name>|off|reload|list|cache status|cache
  clear]`; cache restore at run start + save at end, headless included.
  `SharedSetting.cubeSandbox` is cli-only (host process sandboxing; app
  shells already confined). Contract + reference: `schema/cube_schema.json`
  and `docs/cubes.md`; mock-LLM integration suite
  `test/integration/fa_cube_integration_test.dart` (8 scenarios,
  `--tags integration`).
- `lib/src/prompts/prompt_overrides.dart` — `prompts:` config section maps
  prompt names to file path or inline text; strict validation; flags
  `--system-prompt(-file)` > config > built-in.
- `lib/src/cli/cli_help.dart` — full `fah --help` text, guarded by
  `test/cli/cli_help_test.dart` (update BOTH).
- `lib/src/web_search/` — `web_search` (DDG keyless → Brave/Tavily keyed)
  and `web_fetch` (HTML→markdown, pub.dev handler) via
  `builtinTools(env, webSearch:)`.
- `lib/src/model_roles/provider_catalog.dart` — provider table (incl. the
  `chatgpt` Codex-backend entry, kind `chatgpt-codex`); specs
  default `input: ['text','image']` (vision). The `FA_PROVIDERS`
  dart-define / runtime env (`providerFilterEnvOverride`, wired from the
  process env in `bin/fah.dart`; the define wins) allowlists the catalog
  per build — `enabledProviders`/`providerEnabledInBuild`/`catalogProvider`
  all honor it, default is everything on
  (`test/build_filter/provider_filter_test.dart`).
  Issue #273 token architecture: `buildCatalogModel`/`buildCliDefaultModel`
  resolve `maxTokens` as config override > `resolveModelMaxOutputTokens`
  (the kimi-code per-family Claude OUTPUT ceiling table with
  nearest-lower-minor fallback, 128000 conservative unknown fallback —
  scoped to the `anthropic-messages` api family, `anthropicMessagesApi`;
  claude ids on other dialects keep the provider default, issue #302) >
  provider spec default;
  `lib/src/providers/thinking.dart` ports pi's
  thinking ladder (budgets 1024/2048/8192/16384, `minAnswerTokens` 1024,
  `adjustMaxTokensForThinking` — thinking fits INSIDE `max_tokens`),
  wired into the anthropic adapter via `AnthropicOptions.thinkingLevel`.
  `lib/src/providers/chatgpt_oauth.dart` + `chatgpt_codex.dart` — ChatGPT
  account sign-in (PKCE against auth.openai.com, Codex CLI client id) and
  the Responses-API SSE adapter (`store: false` — the backend rejects
  server-side storage; `ChatGPT-Account-ID` header; 401 → refresh →
  re-persist via `ChatGptCredentialsPersist`). CLI:
  `/provider chatgpt oauth [headless]` (callback server in
  `lib/src/cli/chatgpt_oauth_server.dart`, exported from `lib/io.dart`);
  the credentials blob lives in the secure store as
  `CHATGPT_OAUTH_CREDENTIALS`.
  `lib/src/providers/codemie_sso.dart` + `lib/src/cli/codemie_sso_server.dart`
  (io.dart export) — CodeMie organization sign-in: `/provider codemie sso
  [orgUrl]` runs the browser SSO (login URL embeds the RANDOM callback port;
  the base64 `token` callback carries session cookies); the
  `codemie_access_token` JWT authenticates as Bearer against
  `<org>/code-assistant-api/v1` — the org is saved as a custom provider
  entry (re-login refreshes the key, keeps the last-used model). Models come
  from `/llm_models?include_all=true` (LiteLLM shape), not `/models`;
  `_refreshModelCache` branches on the `code-assistant-api` marker. The
  catalog also has a `codemie` entry for the manual
  `/provider codemie [url] [token]` path (env `CODEMIE_API_KEY`).
  `lib/src/providers/dial.dart` — the `dial` catalog entry (EPAM DIAL Core):
  OpenAI-completions payload, but chat at `{baseUrl}/openai/deployments/
  {model}/chat/completions` (the deployment name lives in the PATH — via the
  `OpenAICompletionsOptions.urlBuilder` extension point) with `Api-Key`
  header auth (the adapter gets a null key so no `Authorization: Bearer` is
  sent); optional `?api-version=` from the `DIAL_API_VERSION` env
  (`_catalogStreamFunction` reads it via `config.envVarValue`). Models come
  from `{baseUrl}/openai/models` (`fetchDialModels`, the
  `_refreshModelCache` `provider == 'dial'` branch). Headless:
  `--provider dial --model <deployment> [--base-url …]` (dial has no
  default model id — `buildCliDefaultModel` throws without `--model`).
  `lib/src/model_roles/vision_models.dart` — the shared vision heuristic
  (`modelIdSuggestsVision`, `visionMarker` picker checkmark,
  `inputModalitiesFor`): CLI model switches recompute `Model.input` from it
  and the model pickers show the ✓/✗ marker; `packages/fa_ui` re-exports it
  (one marker list for CLI and app).
  `lib/src/providers/models_for_endpoint.dart` — the shared "list this
  endpoint's models" dispatch (`fetchModelsForEndpoint`): CodeMie
  `/llm_models` by URL marker, DIAL deployments by `provider: 'dial'`,
  else OpenAI `/models`; every model picker (CLI flows, app pages) routes
  through it so no dialect silently degrades to manual entry.

