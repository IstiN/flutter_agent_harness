# JS extensions

Sandboxed JS add-ons (issue #32) that extend the agent with tools, hooks,
slash commands, and provider flows. An extension is a `manifest.json` +
`main.js` pair installed from a trusted source; the host runs each one in
its own JS engine and exposes a minimal `jsr.ext.*` bridge — nothing else.
Untrusted code never runs: every install passes a trust prompt (or a
`--pin`/`--trust` headless grant), and the manifest declares every
capability the host is asked to expose.

## Quickstart

```
my-ext/
├── manifest.json
└── main.js
```

```json
{
  "name": "hello-ext",
  "kind": "cli-extension",
  "version": "1.0.0",
  "description": "Hello world",
  "platforms": ["cli", "macos", "linux", "windows"],
  "capabilities": { "tools": true }
}
```

```js
// main.js — ES2020, no modules; touches only jsr.ext.* and standard
// built-ins so it runs identically on every engine adapter.
(function (g) {
  'use strict';
  var ext = g.jsr.ext;

  ext.registerTool({
    name: 'hello_ext_greet',
    description: 'Greets a person by name',
    schema: { type: 'object', properties: { name: { type: 'string' } } },
    tier: 'read',
    call: function (args) { return 'hello, ' + ((args && args.name) || 'world'); }
  });

  ext.registerSlashCommand('hello-ext', {
    description: 'Say hello from the extension',
    run: function (args, io) { io.writeln('hello from hello-ext'); }
  });
})(globalThis);
```

```
fa ext install ./my-ext     # TOFU prompt: capabilities + sha256 → y
fa                          # then: /hello-ext  — and the model can call hello_ext_greet
```

## Manifest

Strict parse: every problem accumulates into one error (E12), never
half-loads. Unknown keys are ignored (forward compat).

| Field | Rules |
|---|---|
| `name` (or `id`) | Required, `^[a-z][a-z0-9-]{1,63}$`. |
| `kind` | `cli-extension` \| `widget` \| `hybrid`; absent ⇒ `widget`. |
| `version` | Required, non-empty string. |
| `description` | Optional string. |
| `platforms` | List of `cli`, `macos`, `ios`, `android`, `web`, `linux`, `windows`; absent ⇒ all. An unsupported platform is a load skip (`unsupported here`). |
| `capabilities` | Everything defaults to denied; see below. |

Capabilities — flat booleans (`network`, `keys`, `tools`, `menus`), plus
nested forms for the parameterized ones:

```json
"capabilities": {
  "tools": true,
  "menus": false,
  "keys": false,
  "network": false,
  "fs": { "read": true },
  "exec": { "allowedCommands": ["dart", "grep"] },
  "hooks": ["afterToolCall", "onSessionEnd"]
}
```

`exec.allowedCommands` is a first-token prefix allowlist; `fs.read` (or flat
`fs: true`) enables the read-only file bridge; `hooks` lists the events the
extension registers. The user grants this snapshot at trust time; a diff on
update re-prompts.

## The `jsr.ext.*` API

Everything an extension can do. Bridge rejections resolve to errors carrying
`{error: '<message>'}`.

### `registerTool(def)` → handle

`def = {name, description?, schema?, tier?, call}`. `name` must match
`^[a-z][a-z0-9_]{2,63}$` and becomes the model-facing tool name. `schema` is
a JSON-schema-ish parameter object (`{}` when absent). `tier` is the
approval tier — `read`, `write`, or `exec` (default) — enforced by the
approval gate at call time. `call(args)` returns `String`, `{text}`, or
`{error}` (or a Promise of those); the host enforces a 120 s per-call
budget. Requires the `tools` capability.

### `onHook(event, fn)` → handle

Register a lifecycle callback; `fn(payload)` may return a value or a
Promise. Six events:

| Event | Payload | Return contract |
|---|---|---|
| `onSessionStart` | `{}` | Ignored. Side effects via `session.*`. |
| `onSessionEnd` | `{}` | Ignored. Pending follow-ups deliver first (`[ext:<name>] `-prefixed). |
| `beforeToolCall` | `{tool, args}` | `undefined`/anything else ⇒ allow. `{block: true, reason?}` ⇒ block with `[ext:<name>] <reason>`. `{prompt: reason}` ⇒ v1 maps to a block with reason `[ext:<name>] confirmation required: <reason>` — there is no interactive confirm yet. |
| `afterToolCall` | `{tool, args, result, isError}` | `{append: text}` ONLY — one text block appended to the base result (see redaction ordering). Rewrites and unknown shapes are logged and ignored. |
| `prepareNextTurn` | `{}` | v1 read-only: any non-null result is rejected with a log line (E3). Register now, act later. |
| `onSteering` | — | Registered but never fired in v1. |

The existing (approval + redaction) hooks run before the JS hooks — a JS
`beforeToolCall` can only ever add a block, never lift one.

### `registerSlashCommand(name, opts)` → handle

`opts = {description?, run(args, io)}`. `name` matches
`^[a-z0-9-]{1,31}$` (a leading `/` is stripped), stored bare — the user
types `/<name>`. The host invokes `run` with the split argument list and an
`io = {write, writeln}` pair. No capability needed.

### `menus.registerProviderFlow(def)` → handle

`def = {id, title?, description?, fields, onSubmit}`. `id` matches the
slash-name pattern; the host namespaces it `ext:<extension>:<id>` (E10) so
flows from different extensions cannot collide. `fields` is
`[{name, label, secret?}]`; the host prompts them sequentially and calls
`onSubmit(values)` with the collected `fieldName → value` map (secrets
included — the host persists them, JS never sees them stored). `onSubmit`
returns `{providerName?, baseUrl, apiKey?, modelName?}` or `null` to
cancel. Requires the `menus` capability.

### `session.appendNote(text)` / `session.enqueueFollowUp(text)` → null

Append a session note, or queue a follow-up prompt delivered at session end
(prefixed `[ext:<name>] `). An extension keeps at most `maxPendingFollowUps`
(default 1) follow-ups between deliveries; overflow collapses the whole
queue plus the new text into ONE aggregated entry `<n> follow-ups
collapsed: <first> …` (E14) — a runaway extension cannot flood the next
turn.

### `fs.readFile(path)` → Promise\<String\>

Read-only, confined to the project root: paths normalize lexically, and
absolute paths or `..` escapes are rejected. Rejects on escape, denial, or
missing file. Requires the `fs` capability.

### `exec.run({command, args?, timeoutMs?})` → Promise\<result\>

Resolves `{exitCode, stdout, stderr, timedOut}`. `command` must
first-token-prefix-match an `exec.allowedCommands` entry — anything else is
refused before spawn. `timeoutMs > 0` caps the run (overrun ⇒ `exitCode:
-1`, `timedOut: true`); omitting it leaves the run bounded only by the
enclosing hook/tool budget. Requires the `exec` capability.

### `keys.request(name)` → Promise\<{granted, name}\>

Asks the host whether a stored key resolves for `name`. The bridge NEVER
returns the value — only the `granted` boolean. Requires the `keys`
capability.

### `io.write(text)` / `io.writeln(text)` → null

Print to the host's output sink (the REPL transcript). `io.writeln` appends
the newline host-side.

### `has(capability)` → Promise\<bool\>

`'exec'`, `'fs'`, `'keys'`, `'network'`, `'tools'`, or `'menus'` — gate your
own code paths instead of catching rejections.

## Engines & availability

The host talks to engines only through the `JsrRuntime` seam; one engine
instance per extension (no shared state, ever):

| Surface | Engine | Transport |
|---|---|---|
| CLI | quickjs-ng (`qjs`) subprocess | line-delimited JSON on stdio; the script runs as `qjs --std <file>` — `--std` exposes the `std` module the transport needs |
| Flutter app (native) | flutter_js, in-process | host-driven send-message loop |
| Flutter app (web) | web worker | `postMessage` envelope |

CLI binary resolution: explicit override → `FA_QJS_BIN` → `qjs` on `PATH`.
A missing binary degrades cleanly: the extension is skipped with
`engine unavailable: install quickjs-ng (qjs) and ensure it is on PATH, or
set FA_QJS_BIN` — the session never crashes. `fa ext list` prints the
engine line up front. Availability gates hiding: an extension that cannot
load (engine, platform, trust) is tombstoned with its reason in `/ext list`
and its tools never reach the model.

## Install & trust

```
fa ext install <source...> [--pin <sha256>] [--trust] [--strict]
```

| Source | Form |
|---|---|
| Local directory | `./my-ext` — `manifest.json` + `main.js` at the root, plus extra TEXT files (dotfiles and binaries are skipped) |
| Local zip | `./my-ext.zip` — extracted with hostile-zip rules (no absolute/`..`/backslash entry names) |
| GitHub | `gh:owner/repo` (or `https://github.com/owner/repo`) — root `manifest.json`, branch archive from codeload; provenance `owner/repo@<sha>` |
| Catalog | `catalog:<id>` or a bare id — sha256-verified zip from the fa_widgets release assets |
| Bundled | `--bundled [name]` — first-party content shipped with the binary, auto-trusted |

Trust is TOFU (trust on first use): the first install of a hash prompts with
the extension identity, its content sha256, and the capability snapshot.
Headless/CI: `--trust` grants the FIRST install without a prompt (it does
not bypass update re-prompts); `--pin <sha256>` rejects any content not
hashing to the pin before anything is written; `--strict` turns a denied
decision into exit 1.

Updates re-run the same machinery: same hash ⇒ up-to-date; hash-only change
⇒ silent re-grant; a capability DIFF vs the granted snapshot ⇒ re-prompt
(denial keeps the existing install). `fa ext audit <name>` prints the trust
record — source, provenance, content sha256, granted-at.

Loading enforces trust a second time: a non-interactive host never prompts,
so untrusted extensions tombstone-skip (`untrusted`) instead of running.

## bootstrap.yaml

Project then user, every normal start, idempotent per config content:

```yaml
# <project>/.fah/bootstrap.yaml  and/or  ~/.fah/bootstrap.yaml
extensions:
  - source: catalog:crap-guard
  - source: gh:acme/team-guard
    pin: 9f2c…          # optional sha256; mismatch rejects loudly
  - source: ./vendor-ext
```

Strict schema: only the `extensions` key, entries only `source` + `pin` —
any violation names the key and the file is skipped. Project wins: a user
entry for an extension the project already provides is reported and skipped
(E16). Failures are NAMED lines on stderr and never abort the start (E15);
`FA_EXT_BOOTSTRAP_STRICT=1` makes them fatal instead. A content-hash marker
under the store prevents re-applying the same config.

## `/ext` REPL family

| Command | Effect |
|---|---|
| `/ext list` | Every stored extension: scope, kind, version, trust, live state (`enabled` / `disabled` / `untrusted` / `unsupported here`). |
| `/ext enable <name>` / `/ext disable <name>` | Live via the host — the tool registry and prompt rebuild immediately. |
| `/ext audit <name>` | Trust record + install provenance. |
| `/ext remove <name>` | Live-disable, then delete the stored directory. |
| `/ext update <name> [source]` | Re-plan through the install machinery (TOFU / capability-diff prompts included); `/ext reload` to load it. |
| `/ext reload` | Dispose the live host and re-run the load. |

Headless equivalents: `fa ext list [--json] | install | remove | update |
audit`. `enable`/`disable` are REPL-only.

## Security model

- **Deny-precedence.** The agent's own `beforeToolCall` hook (approval
  gate) runs first; if it blocks, extension hooks never run. JS can only
  tighten.
- **Redaction ordering.** The redaction `afterToolCall` pass masks the base
  result BEFORE extension hooks see it, and every `{append}` an extension
  returns is redacted AGAIN before persisting — extension text can never
  smuggle a secret into the JSONL (issue #24 pipeline).
- **Isolation.** One engine per extension; no shared globals, no
  other-extension state, no transcripts through the bridge.
- **Timeouts everywhere.** Load 30 s, hook 10 s, tool 120 s; a qjs overrun
  is SIGKILLed. Any hook failure or timeout degrades to a log line — no
  extension exception ever escapes into the agent loop.
- **Keys stay host-side.** `keys.request` returns `granted` only; secrets
  collected by provider flows are persisted by the host.
- **Capability vs approval.** The manifest capability is the *prerequisite*
  granted at trust time; the tool `tier` is the *approval gate* evaluated at
  every use. Declaring `exec` does not exempt a call from approval.

## Publishing

The first-party catalog lives in `js-ext-registry/` — see
[js-ext-registry/README.md](../js-ext-registry/README.md) for the repo
layout, the zip + sha256 recipe (`shasum -a 256`), and the exact
`catalog.json` entry of the bundled `crap-guard`.

## v1 limits

- `afterToolCall` is append-only — no `{rewrite}` of tool results.
- `prepareNextTurn` is read-only (any result rejected, E3).
- `onSteering` registers but never fires.
- The Flutter app loads trusted-only extensions; there is no trust UI yet.
- `network` is declarable and grantable but no network bridge method exists
  yet — `has('network')` gates future code, nothing today.
