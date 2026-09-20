# Tool availability

**Tool availability** (issue #19) decides, per tool id, whether the model
sees a tool at all: a `tools:` config section stacks four scopes —
global, project, session, runtime — over the host's hard capability
floor, the deepest scope that mentions a tool wins, and a live gate
applies the merged decision. Disabling a tool unregisters it (the prompt
no longer offers it) and a late call answers a tombstone note instead of
executing. Config can only turn a present tool OFF: a tool the platform
cannot provide stays off no matter what any scope asks. Load modes
(issue #680) are the orthogonal axis — how much of the ENABLED set is
loaded into the schema at boot (see **Load modes** below).

## A full example

```yaml
# ~/.fah/config.yaml — GLOBAL scope: every project on this machine.
tools:
  web_search: false
  mcp:
    fs: false                  # per-server granularity (mcp:<server>)

# <project>/.fah/config.yaml — PROJECT scope: travels with the repo.
tools:
  generate_video: false

# <sessions dir>/.tools/<sessionId>.yaml — SESSION scope: one session.
tools:
  bash: false

# RUNTIME scope — deepest of all. The flag:
#   fah --tools 'generate_video=on,bash=off,mcp:fs=on'
# or its env twin for Docker/headless hosts that cannot pass flags:
#   FA_TOOLS='web_search=on' fah
```

Every omitted tool id stays enabled. An empty or absent `tools:` section
in any file means "no intent from this scope" — the resolution then falls
through to the deeper scopes and finally the platform default.

## Yaml reference

One top-level map, `tools:`, mapping tool id → boolean. Values are
`true`/`false` (absent = enabled). Keys are the flat ids below plus
`mcp:<server>` for per-server MCP granularity — the nested yaml shape
`mcp: {<server>: bool}` flattens to the same key. A non-map section or a
non-boolean value is a parse error: the host warns and ignores that
scope (keeping the last good one), it never crashes startup.

| Key | Notes |
|---|---|
| `read`, `write`, `edit`, `ls`, `bash`, `schedule_message`, `ask`, `request_secret`, `checkpoint`, `rewind`, `generate_image`, `generate_video` | Always wireable; config is the only thing that can turn them off. |
| `bash_job` | The background-shell family (`bash_job status/output/stop`). |
| `memory` | Aggregate for `memory_add`/`memory_search`/`memory_list`/`memory_delete`. |
| `task` | Aggregate for the subagent family: `task`, `task_cancel`, `task_status`, `task_observe`, `task_send`, `agent_directory`, `reply`, `agent_message`. |
| `web_search` | The web family: one id gates BOTH the `web_search` and `web_fetch` tools — there is NO standalone `web_fetch` key. Present only when a web-search provider is configured. |
| `sqlite` | `read`'s SQLite targets. Present only when a SQLite engine is wired; without one the id reads as platform-off. |
| `lsp` | Present only when a language-server transport is wired. |
| `inspect_image` | Present only when a vision model is configured. |
| `transcribe_audio` | Present only when a transcription endpoint is configured. |
| `mcp` | The MCP kill-switch: `false` forces every declared server off (and undeclared servers follow it). Present only when an `mcp:` config section exists. |
| `mcp:<server>` | One MCP server (e.g. `mcp:fs`). Deepest mention wins per server; servers no scope mentions stay enabled. |
| `dap` | The `dap_*` hub tools (docs/dap.md). Present only when a hub is configured. |
| `browser` | The browser family: all eleven `browser_*` tools (`browser_navigate`, `browser_tabs`, `browser_switch_tab`, `browser_click`, `browser_type`, `browser_press_key`, `browser_select`, `browser_read_dom`, `browser_eval`, `browser_screenshot`, `browser_wait_for`). Present only while a browser extension is paired on the bridge; a disconnect hides the family live and the prompt is rebuilt with the reason. |
| `browser_eval` | `browser_eval` alone — its own id so in-page JS evaluation can be disabled without hiding the rest of the browser family (issue #23). |
| `outlook` | The office family: `outlook.read_current_item`, `outlook.read_attachment`, `outlook.insert_draft_body`. Office.js is host-bound — the tools register only inside the Outlook add-in; every other surface lists a gated row with the add-in-only reason instead of staying silent (issue #327). |
| anything else | Unknown id: one warning line, then ignored — never fatal. |

## Scopes

Deepest wins, per key — a shallower scope's say-so loses the moment a
deeper one mentions the same id:

1. **Global** — `~/.fah/config.yaml`.
2. **Project** — `<cwd>/.fah/config.yaml` (travels with the repo).
3. **Session** — `.tools/<sessionId>.yaml` next to the session's JSONL.
   Keyed by session id on purpose: the sessions directory is shared by
   every session of a workspace, and a flat file would leak one
   session's overrides into all of them. An absent file means the scope
   is empty.
4. **Runtime** — the `--tools` flag, else the `FA_TOOLS` env twin (the
   flag wins when both are set).

Hard rules the stack cannot override:

- **Capability is the floor.** A tool whose capability is absent (no
  SQLite engine, no language-server transport, no web provider, no
  vision model, no transcription endpoint, no `mcp:` config, no
  configured hub) resolves to off at the platform level; `true` in any
  scope cannot revive it. Present tools are on by default — only config
  turns them off.
- **Unknown ids warn once** per distinct id and are ignored.
- **A broken scope file warns and is skipped**, keeping the last good
  scope instead of silently falling back to empty.
- **`mcp: false` kills everything MCP**: per-server values union across
  scopes (deepest wins), then the aggregate kill-switch forces every
  declared server to `false` — and servers no scope declared also follow
  the aggregate decision.

## Load modes

**Load modes** (issue #680) decide how much of the available tool set is
LOADED into the provider-facing schema at boot — after oh-my-pi's
`essential-tools` model: a curated base loads, everything else stays
**discoverable** (enabled but out of the schema until mounted on demand).
A mode never disables anything: every enabled tool stays enabled, and
`tools:` scopes resolve exactly as above — the preset only picks which
enabled ids sit in the prompt from the start.

| Mode | Schema at boot | Everything else |
|---|---|---|
| `default` | Every enabled tool — no preset, byte-identical to pre-#680 behavior. | — |
| `pi` | `read`, `write`, `edit`, `bash` (pi-mono's exact benchmark shape, issue #679). | Discoverable, **discovery off** — no `discover_tools`; switch modes to load more. |
| `omp` | `read`, `write`, `edit`, `bash`, `ls`, `task`, `ask`. | Discoverable, **discovery on** — listed/mounted via `discover_tools`. |

Three surfaces pick the mode, deepest wins (issue #680 AC3): the
`--omp` flag (boots the omp preset outright), the `FA_AGENT_MODE` env
twin (`default|pi|omp`, for Docker/headless hosts that cannot pass
flags), and the `agent.mode` config key (any scope file, same labels).
An unknown label from env or config is a hard startup error — a typo
must never silently boot the default mode. The CLI `/settings` "Load
mode" picker switches live: it writes `agent.mode` and re-applies
without a restart.

Demotion rules (what a preset pushes to discoverable):

- Every ENABLED id outside the preset's essential set — static tool ids
  and `mcp:<server>` families alike (MCP schemas are the heaviest; the
  card lists `mcp__*` among the discoverable).
- An explicit `tools: {id: on}` in any scope is a **standing mount**:
  the id loads even under a preset (the user asked for the tool; the
  preset only curates the default). Per-server `tools: {mcp:<server>: on}`
  and the aggregate `tools: {mcp: on}` keep MCP families loaded the same
  way.
- An explicit `off` still disables — disable is disable, never demotion;
  the essential set itself is pinned (nothing in the scope stack can
  demote it).

### The `discover_tools` surface

`discover_tools` is the discovery meta tool of the omp mode — registered
ONLY in omp (`discoveryEnabledByLoadMode`; the availability rebuild
syncs it, so a mid-session `/settings` mode switch registers or
unregisters it live). It carries no availability id, so it sits outside
the `tools:` scope stack — no config can hide it. Pi keeps pi-mono's
exact four-tool shape with discovery off (issue #679), and the default
mode never sees it.

Called with no arguments it lists every discoverable-and-unmounted tool
with a one-line doc; with `mount: [names]` it loads those tools into the
schema for the rest of the session (a mount is session-scoped and
survives availability re-applies — nothing unmounts automatically; there
is deliberately no GC). Mounting re-applies the availability resolution,
so the tool enters the registry and the prompt rebuilds.

A call to a discoverable tool that is not mounted never executes: the
executor answers a tombstone that follows the live mode — while the
discovery surface is registered (omp) it says to call `discover_tools`
and mount by name; in a mode without it (pi) it points at the
`/settings` load-mode switch (`agent.mode`) and this page instead of a
tool that mode never shipped.

## Runtime

Slash commands (line mode):

| Command | Effect |
|---|---|
| `/tools` | One line per known id: approval tier, on/off, deciding scope, and (when off) the reason. |
| `/tools enable <id> [global\|project\|session]` | Persist `true` and re-apply. Default scope: project. |
| `/tools disable <id> [global\|project\|session]` | Persist `false` and re-apply. Default scope: project. |
| `/tools reload` | Re-read every scope from disk and re-apply. |

Nothing needs a restart. Re-applying a resolution is idempotent: enabled
ids get their tools (re-)registered, disabled ids unregistered, the tool
list in the agent state and the provider-facing prompt refresh, and
disabled MCP servers re-filter live without a server restart. The `read`
tool follows the `sqlite` decision by swapping variants in place — same
snapshot store and hashline anchors, only the description (with or
without the SQLite section) and the engine change. A toggle that cannot
persist (broken/unwritable file, no active session for the session
scope) leaves the live state untouched.

Concurrent writers to the same scope file are last-writer-wins: two
`fah` processes toggling tools in one project can drop each other's
`tools:` change (the same behavior as every other config write).

A call to a disabled tool never executes: the executor answers a plain
tombstone text — the tool name, the why (`disabled by <scope>` or the
capability's absent reason), and a pointer to re-enable via `/tools` or
settings — so the model can react instead of crashing the turn.

## Surfaces

- **CLI `/settings`** — a Tools entry (label: "N of M tools available")
  opening a picker flow: pick a tool, pick enable/disable, pick the
  scope to persist in (project default, session, or global — the global
  file is host-owned and written through the persistence hook).
- **`--tools` / `FA_TOOLS`** — the runtime scope for CI and headless
  runs: `--tools 'web_search=off,mcp:fs=on'`, values
  `on`/`off`/`true`/`false` case-insensitive. The flag wins over the
  env twin; a malformed spec is a hard startup error either way — a
  typo must never silently enable a tool meant to be disabled.
- **Flutter app** — a Tools section in settings: one switch per known
  id, applied to the running agent immediately (no restart). Rows for
  ids the app cannot wire render disabled with the capability's reason.
  Choices persist to `tools_availability.json` (versioned JSON envelope,
  the same `ToolsConfig` shape the CLI parses).
- **DAP gating** — the `dap_*` tools register only when a hub is
  actually configured (resolution: env > `hub:` section >
  `~/.dap/config.json` > default — docs/dap.md §9). A zero-config
  install hands the model no hub tools (every call would dead-end); the
  `/dap <host>` command and the inbox stay unconditional, and after a
  connect the tools appear on the next launch. Connecting mid-session
  never exposes the family ungated: with the hub unconfigured at boot
  the `dap_*` tools are not registered for that session at all (the
  next launch registers them, still subject to `tools.dap`), and when
  they were registered but disabled by config the gate keeps them
  hidden for the whole session. Once configured, `dap: false` in any
  scope turns the family off like any other id.
