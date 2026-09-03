# Tool availability

**Tool availability** (issue #19) decides, per tool id, whether the model
sees a tool at all: a `tools:` config section stacks four scopes —
global, project, session, runtime — over the host's hard capability
floor, the deepest scope that mentions a tool wins, and a live gate
applies the merged decision. Disabling a tool unregisters it (the prompt
no longer offers it) and a late call answers a tombstone note instead of
executing. Config can only turn a present tool OFF: a tool the platform
cannot provide stays off no matter what any scope asks.

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
  connect the tools appear on the next launch. Once configured, `dap:
  false` in any scope turns the family off like any other id.
