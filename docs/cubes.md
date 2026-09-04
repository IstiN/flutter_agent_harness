# Cubes

A **cube** is a declarative sandbox profile for a Fa run: a strict yaml
manifest that clamps which commands may execute, which hosts may be
reached, which paths may be touched, which environment variables the run
sees, and how much time and disk the run may consume. Manifests live in
`.fah/cubes/<name>.yaml` inside a project; `/cube` manages them live.

Fa parses cube manifests **strictly**: a wrong `apiVersion`, a bad name,
or an unknown key at any level is a loud startup error — a broken manifest
never fails open into an unconfined run.

## A full example

```yaml
apiVersion: fa/v1
kind: Cube
metadata:
  name: web-scraper
  description: "Fetches documentation pages and extracts text."
spec:
  tools:
    allow: [curl, wget, "git*"]
    deny: ["git push"]
  network:
    allow:
      - {host: "*.example.com", ports: [80, 443]}
      - {host: api.github.com, ports: [443]}
    deny:
      - {host: "*", ports: [22, 3389]}
  filesystem:
    workspace: /workspace
    mounts:
      - {path: /usr/share/doc, access: ro}
      - {path: ~/.ssh, access: deny}
  env:
    - {name: FAH_MODE, value: sandboxed}
    - {name: SCRAPER_KEY, valueFrom: "env:API_KEY"}
    - {name: HOME, hidden: true}
  resources:
    limits: {cpu: "50%", memory: 512Mi, disk: 100Mi}
    timeout: 3600s
  cache:
    enabled: true
    paths: [/workspace/.cache]
    restore: true
    ttl: 24h
```

Safe defaults apply to every omitted section: deny-all tools, deny-all
network, workspace `/workspace` with no mounts, host environment passed
through unchanged, no resource limits, and caching disabled. A cube with
no `spec:` at all confines nothing but runs nothing.

## Yaml reference

A JSON Schema for this document lives at `schema/cube_schema.json`
(draft 2020-12) — it mirrors the parser below.

### Document

| Key | Type | Notes |
|---|---|---|
| `apiVersion` | string | Required. Exactly `fa/v1`. |
| `kind` | string | Required. Exactly `Cube`. |
| `metadata.name` | string | Required. `^[a-z][a-z0-9-]*$`. |
| `metadata.description` | string | Optional. |
| `spec` | map | Optional; every subsection below is optional. |

### `spec.backend`

`policy` (default) or `kernel`. **kernel — OS confinement**: selects the
hard OS boundary in addition to the Dart policy layer; `policy` enforces
in Dart only.

### `spec.tools`

| Key | Type | Notes |
|---|---|---|
| `allow` | string list | Command word(s) that may run. An entry matches exactly, as a word-boundary prefix (`git push` matches `git push -f`), or with a trailing `*` as a character-level prefix (`git*` matches `git` and `gitk`). Empty (or absent) = deny everything. |
| `deny` | string list | Always refused, even when `allow` matches. Deny wins. |

### `spec.network`

`allow` / `deny` rule lists. A rule is a bare host string (any port) or
`{host, ports}`; omitted or empty `ports` means any port. Hosts match
exactly (case-insensitive), `*` matches everything, `*.domain` matches
the apex and any subdomain but never `notexample.com`. IP literals match
exactly. Deny wins; an empty `allow` denies all network.

### `spec.filesystem`

| Key | Type | Notes |
|---|---|---|
| `workspace` | path | Read/write root; absolute or `~/`-relative. Default `/workspace`. |
| `mounts` | list | `{path, access}` with access `ro`, `rw`, or `deny`. The **longest matching mount wins**; otherwise paths inside the workspace are read/write and everything else is denied. |

Path checks are pure string math: `~` is expanded, `.`/`..` segments are
collapsed (climbing above `/` is denied), and symlinks are judged by
their written form.

### `spec.env`

A list of `{name, value}`, `{name, valueFrom}`, or `{name, hidden}` —
exactly one of the three per entry, no duplicates:

- `value: <string>` — literal value injected into the run.
- `valueFrom: "env:NAME"` — read from the host environment at run start;
  a missing source is simply absent.
- `hidden: true` — removed from the child environment.

A non-empty `env` starts the run from a clean environment: only `PATH`,
`HOME` and `TMPDIR` survive from the host (each droppable by declaring it
hidden or overriding it). An absent `env` section passes the host
environment through unchanged.

### `spec.resources`

| Key | Type | Notes |
|---|---|---|
| `limits.cpu` | string | Kept verbatim (e.g. `"50%"`), interpreted by the enforcing backend. |
| `limits.memory`, `limits.disk` | size | Integer bytes or `512Mi`-style: `B`, `K`/`KiB` (1024), `KB` (1000), `M`/`Mi`/`MiB`, `MB`, `G`/`GiB`, `GB`, case-insensitive. `disk` prunes old cache entries. |
| `timeout` | duration | Integer seconds or `3600s` / `5m` / `24h` (single unit; `1h30m` is rejected). Clamps every shell command of the run. |

### `spec.cache`

| Key | Type | Notes |
|---|---|---|
| `enabled` | bool | Defaults `true` when the section is present; the absent section disables caching. |
| `paths` | path list | Cube-relative directories snapshotted between runs. |
| `restore` | bool | Defaults `true`; restores caches into a fresh sandbox before the run. |
| `ttl` | duration | Entry lifetime; omitted = no expiry. |

## Resolution order

Which cube applies to a run, highest precedence first:

1. `--cube-config <path>` — explicit manifest file (`~` expanded).
2. `--cube <name>` — `<cwd>/.fah/cubes/<name>.yaml`.
3. `cube:` in the project `.fah/config.yaml`.
4. `cube:` in the user `~/.fah/config.yaml`.

The `cube:` config section takes `enabled:` (default `true`) and
`config:` — a manifest path (anything containing `/`) or a bare name
resolved under `.fah/cubes/`. Requesting a missing or invalid cube is a
hard error, never a silent fallback to an unconfined run.

## CLI surface

Flags:

- `--cube <name>` — apply a cube by name from `.fah/cubes/`.
- `--cube-config <path>` — apply a cube from an explicit manifest path.

Slash commands (line mode):

| Command | Effect |
|---|---|
| `/cube` | Show the active profile: identity, backend, policy summary, cache. |
| `/cube list` | List manifests in `.fah/cubes/`. |
| `/cube use <name-or-path>` | Resolve and enforce a manifest from now on. |
| `/cube off` | Leave sandbox mode (full host access; the boot source is kept for `/cube reload`). |
| `/cube reload` | Re-resolve the remembered source and enforce it again. |
| `/cube cache status` | Show the cache key, root and policy. |
| `/cube cache clear` | Drop the active cube's cache entry. |

## Enforcement layers

| Concern | Dart policy layer | Kernel layer (`backend: kernel`) |
|---|---|---|
| Tools | `SandboxedShell` checks every command of a line (subshells included) against the allow/deny sets; a denied command answers exit 127 with an `fa_cube[<name>]:` note. | Process confinement at exec time. |
| Network | Lexical URL check on `curl`/`wget` arguments only. | Egress control (`--net` when nothing is allowed). |
| Filesystem | `CubeFsGuard` clamps file operations to the fs policy (lexical, per above). | Mount namespace; SBPL `file-read*`/`file-write*` rules. |
| Environment | Clean base + declared vars (additive; cannot strip inherited vars). | Full environment isolation. |
| Resources | Timeout clamp per command; disk cap prunes cache entries. | Backend-interpreted caps. |

Backend selection follows the host OS: macOS generates a `sandbox-exec`
SBPL profile, Linux an `unshare` user-namespace argv prefix, and other
platforms (including Windows) currently report a descriptor-only no-op.

## Confinement contract

- **Denied, not audited.** A refused command or file operation fails with
  a short note (exit 127 for commands); there is no audit log of denials.
- **The Dart layer is a convenience, not a boundary.** The command
  scanner is quote-aware but not a shell parser: redirects, `eval`
  indirection and quoting inside `$( )` are above its ceiling, and the
  network scan sees only `curl`/`wget` URL arguments — bare-host
  operands are unchecked. The fs guard resolves symlinks by their
  written form only.
- **No side-channel guarantees.** Timing, cache and similar side
  channels are out of scope for the Dart layer.
- **Kernel = hard boundary.** As the policy engine's own contract states:
  the kernel sandbox backends (`lib/src/cube/backends/`) are the hard
  boundary; everything above is convenience. Where the full proxy egress
  filtering should live — future work.

## Cache layout

Snapshots land under `<cwd>/.fah/cube-cache/<key>/`, where `<key>` is
the first 10 hex chars of the md5 over the spec's canonical JSON form.
Any spec change — one new tool, one extra path — forks a new entry, so
two runs share caches exactly while their policies agree. Entries expire
by `ttl`, restore honors `restore:`, and `limits.disk` prunes the oldest
sibling entries until the total fits. All cache I/O is best-effort: a
failed copy is skipped, never fatal — a partially restored cache beats a
crashed run.

## Status (fa_cube issue #8)

- **Phase 1 — landed:** manifest parsing, policy engine, sandboxed
  shell/env/fs guards, content-addressed cache, resolver, `--cube` /
  `--cube-config` flags and the `/cube` family.
- **Kernel activation — landed:** `spec.backend: kernel` wraps every
  child process in the OS sandbox — macOS `sandbox-exec -f`, Linux
  `unshare` user namespace (`--net` only when nothing is allowed), clean
  `env -i` environment, `ulimit` ceilings; profiles staged under
  `.fah/cube-profiles/`. Windows remains descriptor-only. A wrapper that
  is missing from PATH or refuses the sandbox surfaces as a clean
  `fa_cube[<name>]:` spawn error, in foreground execs and background jobs
  alike.
- **Network — Dart scan only:** the policy engine checks `curl`/`wget`
  arguments; full egress proxy filtering is future work.
