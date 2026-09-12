---
name: fa-self-config
description: >
  Configure fa (flutter_agent_harness) itself by editing the exact config
  files the CLI settings commands write: provider/model selection and roles,
  memory paths, tool availability, cubes, MCP servers, redaction, skills
  access, approval and mode. Use when asked to reconfigure fa without a human
  in the REPL ("switch us to provider X", "point project memory at this
  path", "disable web_search for this project").
when_to_use: Reconfiguring fa itself — settings, provider, models, memory,
  tools, cubes, MCP, redaction, skills access — on any host (CLI headless,
  REPL, app), by editing the YAML config the CLI persists, never by guessing
  keys.
argument-hint: "[what to configure, e.g. 'point project memory at ./memory']"
allowed-tools:
  - read
  - write
  - edit
  - ls
  - bash
  - config
user-invocable: true
disable-model-invocation: false
---

# fa self-configuration

You are reconfiguring fa itself. The config file IS the source of truth: the
CLI settings commands (`/provider`, `/tools`, `/approval`, …) are thin
editors over the same YAML this skill edits. Edit the file, never invent
keys, verify after every edit, and report what changed and when it applies.

## Hard rules

1. **Never invent keys.** Unknown top-level keys are ignored silently; strict
   sections throw `ConfigException` on unknown keys or bad value types and can
   break startup — `mcp:`, `memory:`, `cube:`, `providerTimeouts:`, `skills:`,
   `models.custom` fields, `ttsr:`. The `tools:` section throws on non-boolean
   values; unknown TOOL ids only warn (and absent capabilities can never be
   force-enabled). Every key you write must come from this document.
2. **Never write API key VALUES into config.yaml.** Config carries key NAMES
   (`apiKeyName:`) only. Values live in the OS secure store (`/key set`) or the
   environment. A key value in YAML is a leaked secret.
3. **Preserve the file.** Edit surgically (the `edit` tool, or `write` only for
   a file you fully own). Keep comments and unrelated keys byte-identical.
4. **Verify after every edit.** Run the `config` tool's `check` op (or
   `fa config check`) and confirm it passes before declaring success. A
   broken file must be detected by you, not discovered at next boot.
5. **Report scope + application.** Every change report states: which file, which
   scope, and whether it applies live or at next boot.

## Config layout and precedence

| File | Scope | Notes |
|---|---|---|
| `~/.fah/config.yaml` | user (global) | main settings file; loaded by `loadCliConfig` |
| `<project>/.fah/config.yaml` | project | only the `memory:`, `cube:`, `tools:` sections are read from here — each wins over the user file |
| `<project>/.fah/rules.yaml` | project | TTSR stream rules; project rules win name clashes over the `ttsr:` section |
| `<project>/.fah/lsp.json` | project | LSP server map |
| `<project>/.fah/packages.yaml` | project | plugin configuration |
| `~/.dap/config.json` | user | DAP hub identity/channels (written by the `/settings` hub flow, not YAML) |

Project precedence is per section, not per file: `memory:`, `cube:` and
`tools:` are loaded separately from the project file
(`loadProjectMemoryConfig`, `loadProjectCubeSettings`, `loadProjectToolsConfig`)
and win over the same section in `~/.fah/config.yaml`. All other sections are
read from the user file only.

Project sections are strict: a present-but-invalid section throws
`ConfigException` at startup. A project `.fah/` that does not exist yet is
created with a minimal valid file — never leave a half-written YAML behind
(write to a temp name and rename, or write the full content in one `write`).

## Workflow

1. Read the request; identify the topic section below.
2. Inspect current state: `config` op `get <key>` / `path` (or read the two
   config files — a missing file means defaults, not an error).
3. Make the edit: `config` op `set` (preferred — it validates before
   writing and preserves the rest of the file byte-for-byte). Fall back to
   a surgical file edit (rule 3) only for what `set` cannot express:
   removing a key.
4. Verify: `config` op `check` (rule 4).
5. Report (rule 5), naming the CLI command equivalent that would have made
   the same change.

## The config tool

The primary editing surface on every host — CLI, desktop app, web, iOS —
because it needs no shell and no `fa` process. One tool, four ops over the
same core the human CLI verbs wrap:

| op | args | effect |
|---|---|---|
| `check` | — | validate both config files with the real parsers; prints errors, warnings, notes and a final `config check: ok` / `config check: failed` |
| `path` | — | list the config file locations and whether each exists |
| `get` | `key` | the effective value of a dotted key; project scope wins for `memory`/`cube`/`tools` |
| `set` | `key`, `value`, `scope`? | surgical single-key write; the edited file is validated BEFORE the write, so an invalid value persists nothing |

`set` answers with the file, scope, old → new value, and whether the change
applies live or at next boot — echo that in your report (rule 5). `scope`
defaults by key: `memory`/`cube`/`tools` → the project file (created minimal
when absent), everything else → the user file; pass `global` or `project`
to override. Keys come from the topic sections below — the tool rejects
unknown top-level keys instead of writing them.
`set` also takes LIST-VALUED keys: pass the value as compact JSON (an
array or object) and it is rendered as a yaml block — `customProviders`
provider entries are settable this way, e.g. `config` op `set`, key
`customProviders`, value
`[{"name":"my-llama","apiType":"openai","baseUrl":"http://localhost:11434/v1","modelId":"llama3"}]`.
`get` reports list-valued keys as the same compact JSON, so the round
trip is get → edit the JSON → set. A whole list is replaced; to add one
entry, get first and re-set the extended list.
`get` of a platform-inapplicable key and `set` of one answer
`not applicable on this host` with the reason — never write there and
never suggest a file edit as a workaround. The stdio members of an MCP
server (`command`/`args`/`env`) need host process spawning: on web and
iOS/Android containers they are refused; configure a remote server via
`mcp.servers.<id>.url` instead. On a host with no home directory (web)
the global scope is refused for every user-file key — only the project
sections (`memory`/`cube`/`tools`) persist there.

Human/script equivalent (thin wrappers over the same service):
`fa config check`, `fa config path`, `fa config get <dotted.key>`,
`fa config set <dotted.key> <value> [--project|--global]`, and
`fa config export-providers [--out <file.fahx>]` (provider-preset export —
the one verb without a config-file write).

## Verification

`config` op `check` (or `fa config check`) validates both files with the
REAL section parsers and prints named diagnostics — this is the mandatory
final step of every edit:

- **What check reports as errors** (non-zero exit / `config check: failed`):
  yaml syntax errors, strict-section schema errors (`mcp:`, `memory:`,
  `cube:`, `tools:`, `providerTimeouts:`, `skills:`, `roles:`, `ttsr:`,
  `models.custom`), and bad scalar types — each naming file+section.
- **Warnings**: unknown top-level keys (the runtime silently ignores them;
  the check does not — a typo must not survive) and dead project-file keys.
- **At next boot, semantic errors in strict sections are FATAL**:
  `invalid ~/.fah/config.yaml: <named diagnostic>` — the process refuses to
  start rather than boot a broken config. A passing check is what stands
  between your edit and that.
- **YAML syntax errors remain silent at RUNTIME** (an unparseable file falls
  back to defaults) — `check` is the only place they are reported, which is
  why it is mandatory.
- **Live re-read surfaces**: in a running REPL, `/tools reload` and
  `/mcp reload` re-read their sections immediately and print the parse
  error instead of applying it — use them as the live check when a REPL
  exists.
- Runtime objects keep the last good config when a reload fails (the failed
  section never half-applies), so a loud reload error means "nothing changed".

## CLI parity map

Every settings command below has a config-file equivalent documented in this
skill. If a new settings command appears in the CLI without a section here,
this skill has rotted — flag it in your report.

| CLI | Section |
|---|---|
| `/provider`, `/providers` | [Provider & keys](#provider--keys) |
| `/model`, `/models`, `/model-edit` | [Models & roles](#models--roles) |
| `/memory` | [Memory](#memory) |
| `/tools` | [Tool availability](#tool-availability) |
| `/cube` | [Cubes](#cubes) |
| `/mcp` | [MCP servers](#mcp-servers) |
| `/redact` | [Redaction](#redaction) |
| `/skills` | [Skills access](#skills-access) |
| `/approval`, `/allow` | [Approval](#approval) |
| `/mode`, `/code`, `/architect`, `/review` | [Mode](#mode) |
| `/settings` | [Settings hub](#settings-hub) |

<!-- parity: /provider /providers /model /models /model-edit /memory /tools /cube /mcp /redact /skills /approval /allow /mode /code /architect /review /settings -->

The `fa config check|path|get|set` verbs and the `config` tool share their
config-file equivalent with the topic sections above (see
[The config tool](#the-config-tool)); the parity test pins every verb
alongside the slash commands.

## Provider & keys

<!-- parity: /provider /providers -->

User file, top-level keys:

```yaml
provider: openai-completions   # openai-completions | anthropic | google | dial | minimax | zai
model: openai/gpt-4o-mini      # model id sent to the provider
baseUrl: https://openrouter.ai/api/v1
```

Saved custom endpoints (the `/provider custom` flow persists here):

```yaml
customProviders:
  - name: my-llama             # non-empty, unique
    apiType: openai            # openai | anthropic | google | dial | openrouter
    baseUrl: http://localhost:11434/v1
    modelId: llama3            # non-empty
    keyName: MY_KEY            # optional: env/secure-store NAME, never the value
    authMethod: apiKey         # apiKey | sso | jwt (optional)
```

Applies: a direct YAML edit takes effect at next boot. `/provider <name>
[baseUrl] [token]` switches the live session too.
Keys: never inline values (rule 2). Key resolution order — environment value,
then endpoint-scoped secure-store entry (`FA_KEY_<HOST>`), then legacy env-name
store entries. `/key set|delete` manages the store and has NO config.yaml
equivalent — that is deliberate.

## Models & roles

<!-- parity: /model /models /model-edit -->

User file. The active model is the `model:` top-level key (above). Optional
sections:

```yaml
roles:                         # intent → ordered fallback chain
  default:
    - openrouter/anthropic/claude-sonnet-4
    - provider: openai         # or a map entry:
      model: gpt-4o
      apiKeyName: OPENAI_API_KEY   # optional; also baseUrl, contextWindow, maxTokens
  smol: [openrouter/openai/gpt-4o-mini]   # roles: default, smol, slow, plan, subagent, memory
modelOverrides:                # scope chains to path prefixes
  - path: ~/work/acme
    roles:
      plan: [anthropic/claude-opus-4-5]
retry:                         # chain fallback policy
  retriesPerEntry: 2           # + baseDelayMs, maxBackoffMs, maxWaitMs, keyBackoffMs
providerTimeouts:              # strict: only these two keys
  connectTimeoutMs: 180000
  streamIdleTimeoutMs: 300000
models:                        # media slots + named custom models
  slots:
    vision:
      providerKind: openai-completions
      baseUrl: https://api.openai.com/v1
      modelId: gpt-4o
      apiKeyName: OPENAI_API_KEY
  custom:
    fast:
      provider: openai
      baseUrl: https://api.openai.com/v1
      model: gpt-4o-mini
      contextWindow: 128000    # + maxTokens, input
```

Media slot names (exact): `imageGeneration`, `audioTts`, `musicGeneration`,
`videoGeneration`, `vision`, `transcription`. A slot without an override falls
back to the main connection.

CLI equivalents: `/model <id>` switches the active model (a
`models.custom.<name>` switches provider+endpoint+model in one step);
`/models config` displays this section, `/models set <slot> <model>
[baseUrl]` and `/models remove <slot>` edit `models.slots`;
`/model-edit [contextWindow|maxTokens <n>]` overrides token limits for the
session (persist per chain via `roles:` entries instead). Role edits apply at
next boot; `/model` applies live.

## Memory

<!-- parity: /memory -->

The long-term memory location. `memory:` may live in the user file or the
project file — project wins.

```yaml
memory:
  projectPath: ./memory        # inside the repo; committed with it
  userPath: ~/memory           # or a user-level store
```

CLI equivalent: `/memory` shows stats, `/memory maintain` runs consolidation —
neither edits paths; the section is the only way to set them. The live memory
controller re-reads the section (project resolution via `loadProjectMemoryConfig`),
so a path change applies without restart.

## Tool availability

<!-- parity: /tools -->

`tools:` maps a tool id (or `mcp:<server>`) to on/off. Scopes, deepest wins
per key; the host's hard capability floor can never be overridden on:

1. global — `~/.fah/config.yaml` `tools:`
2. project — `<project>/.fah/config.yaml` `tools:`
3. session — `.tools/<sessionId>.yaml` next to the session file
4. runtime — `--tools` flag / `FA_TOOLS` env (this run only)

```yaml
tools:
  web_search: false
  mcp:
    fs: true                   # nested mcp: == mcp:<server> keys
```

CLI equivalent: `/tools enable|disable <id> [global|project|session]` writes
the matching scope file; `/tools` lists every id with its deciding scope;
`/tools reload` re-reads all scopes live. Disabled tools are hidden from the
model and tombstoned at execution. Edits apply live after a reload.

## Cubes

<!-- parity: /cube -->

Sandbox profile selection. `cube:` may live in the user or project file
(project wins). Manifests live in `<project>/.fah/cubes/<name>.yaml`.

```yaml
cube:
  enabled: true
  config: .fah/cubes/strict.yaml   # path to the cube manifest
```

CLI equivalent: `/cube use <name|path>` switches, `/cube off` disables,
`/cube list` lists manifests, `/cube reload` re-reads. Applies live via
`/cube`; a YAML edit applies at next boot (explicit `--cube`/`--cube-config`
flags beat both files).

## MCP servers

<!-- parity: /mcp -->

Strict section — unknown shapes throw `ConfigException`. User file only.

```yaml
mcp:
  toolCallTimeoutMs: 60000
  servers:
    fs:                        # stdio server
      command: npx
      args: [-y, "@modelcontextprotocol/server-fs", /tmp]
      env: {KEY: value}
    docs:                      # remote server
      url: https://example.com/mcp
      transport: streamable-http   # or sse
      headers: {Authorization: "Bearer ${DOCS_TOKEN}"}
```

CLI equivalent: `/mcp` prints per-server status, `/mcp reload` re-reads the
config live (boot never blocks on MCP). Applies live after `/mcp reload`;
connects lazily in the background.

## Redaction

<!-- parity: /redact -->

User file `redact:` section (issue #24 layered pipeline):

```yaml
redact:
  enabled: true
  blockMode: false             # deny credential-file reads outright
  layers:                      # per-layer toggles (priority order in docs/redaction.md)
    pii: true
  allowlist:                   # regex patterns that survive redaction (git SHAs, UUIDs)
    - "[0-9a-f]{40}"
  toolAllow: [bash]            # when non-empty, only these tools are redacted
  toolDeny: [web_fetch]        # never redacted; wins over toolAllow
```

CLI equivalent: `/redact on|off`, `/redact block on|off`, `/redact stats`,
`/redact layers`. The command toggles the live pipeline; the section is the
durable form written back when the CLI persists config. Redaction is
live-mutable — no restart needed either way.

## Compaction

Context-hiding engine choice (issue #148). User or project file (project
wins):

```yaml
compaction:
  engine: structured           # classic | structured (default classic)
```

`classic` keeps the lossy summary compaction; `structured` hides records in
place behind one-line addressable markers (`compact_expand` restores any id
or range under a per-turn token budget). Runtime override:
`fa --compaction-engine structured`; resolution is
session < project < global < flag. Applies at session boot.

## Skills access

<!-- parity: /skills -->

User file section governing third-party skill discovery
(`.claude/`, `.github/skills`, `.codex/`):

```yaml
skills:
  access: granted              # ask | granted | denied
  disableShellExecution: false # strip !`cmd` injections from third-party skills
```

CLI equivalent: `/skills access ask|granted|denied` (and the `/skills` menu).
`/skills import` copies third-party skills into `.fah/skills`. Applies live on
re-discovery.

## Approval

<!-- parity: /approval /allow -->

User file top-level keys:

```yaml
approvalMode: yolo             # always-ask | write | yolo | unattended
allowedTools:                  # always-allow list (exec tier still honors critical patterns per mode)
  - web_fetch
```

CLI equivalent: `/approval <mode>`, `/allow <tool>` — both persist to these
keys. Applies at next boot (the running session keeps its live mode).

## Mode

<!-- parity: /mode /code /architect /review -->

User file top-level key:

```yaml
mode: code                     # code | architect | review
```

CLI equivalent: `/mode <name>` or the `/code`, `/architect`, `/review`
shortcuts — they switch live AND persist this key.

## Prompts, TTSR & A2A

The remaining user-file sections (all global scope):

```yaml
prompts:                        # prompt overrides: prompt id → text or @file
  concise: "Answer in one short paragraph."
ttsr:                           # tool-schema reduction (TTSR)
  enabled: true
  contextMode: keep             # keep | discard
  repeatMode: after-gap         # after-gap | once
a2a:                            # remote Agent2Agent endpoints
  servers:
    peer:
      url: https://peer.example:8080
      token: ${PEER_TOKEN}      # env-resolved at boot — never a literal secret
```

`a2a` servers are remote-only (a `url`, like remote MCP servers), so they
configure fine on process-less hosts. A `token` is an `${ENV}` reference
resolved at boot; config `check`/`set` keep the token text literal, so an
unset variable surfaces when the agent boots, not as a config error.

## Settings hub

<!-- parity: /settings -->

`/settings` is an interactive hub over the surfaces above (provider, model,
approval, cube, keys, MCP, DAP hub). It has no single config equivalent —
each arm edits the section documented for it. DAP hub settings are the one
surface NOT in config.yaml: the hub flow writes `~/.dap/config.json`
(identity keys, channels). Configure DAP through the hub flow or see
docs/dap.md; never hand-edit the DAP files while a hub client is running.

## Example invocations

- `point project memory at ./memory` → Memory section: `config` op `set`,
  key `memory.projectPath`, value `./memory` (project file is the default
  scope — created minimal if missing), then `check`, then report live
  application.
- `switch us to provider X` → Provider & keys: `config` op `set` for
  `provider:` (and `baseUrl:`) in the user file — global scope is the
  default for these keys; report next-boot application and the `/provider`
  equivalent.
- `add custom provider Y and switch to it` → Provider & keys: `config` op
  `get customProviders`, `config` op `set customProviders <extended JSON
  list>` (see the config-tool section), then `set provider openai-completions`,
  `set model <entry modelId>`, `set baseUrl <entry baseUrl>`; verify with
  `check`, report next-boot application and the `/provider` equivalent.
- `disable web_search for this project` → Tool availability: `config` op
  `set`, key `tools.web_search`, value `false` (project scope by default);
  report live after `/tools reload` semantics (host REPL) or next re-read.
- `configure cube backend Z` → Cubes: `config` op `set` for the `cube:`
  keys (project file for a repo default) and reference the manifest in
  `.fah/cubes/`.
