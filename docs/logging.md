# Logging (issue #2117)

The `lib/src/logging/` layer gives the interactive console a noise dial —
levels, categories, and an optional line pattern — while the headless
output contract stays pinned byte-identical.

## Levels

`off < error < warn < info < debug < trace`. A sink at level L passes
every line at or under L; `off` passes nothing. The two sinks filter
independently:

| Sink | Default | What it carries |
|------|---------|-----------------|
| interactive console (TUI/REPL) | `warn` | the important events; chatter hides |
| `~/.fah/logs/fa.log` | `debug` | every diagnostic line, level-tagged |

The level filter governs the **interactive console only**. Headless
stdout — HEP (#155) and stream-json (#695) frames, wire-serve, session
records, finalize/abort markers, plain `fa --session X "prompt"` output —
is contract output, never filtered at defaults. A headless run filters
its human diagnostic lines (stderr) only when you pass `--log-level` or
set `FA_LOG_LEVEL` explicitly; a config-only level never touches headless
output. Any future change to the headless default is a versioned,
changelog'd breaking change, not a side effect.

## Setting the level

Precedence: `--log-level` flag > `FA_LOG_LEVEL` env > project
`.fah/config.yaml` `logging:` > user `~/.fah/config.yaml` `logging:` >
default. Invalid level strings fail loudly at boot — never a silent
fallthrough to `trace`.

```yaml
logging:
  console: warn    # the interactive console dial
  file: debug      # the fa.log dial
  format: "{time} {elapsed} {sid} [{level}/{cat}] {msg}"
  timeFormat: "HH:mm:ss.SSS"
```

`/log <level>` switches the console sink live in the REPL (bare `/log`
prints the current level). `--debug-secrets` / `FA_DEBUG_KEYS=1` remain
as the `keys=debug` alias: keys-category lines keep a `debug` floor on
the console even under a quieter dial — but an explicit `off` stays off.

## Categories

Every log call declares one: `keys`, `lifecycle`, `tool`, `provider`,
`compaction`, `messaging` (default `lifecycle`). The first reassigned
noise classes: the passive `info: agent stalled` banner obeys the console
dial (hidden at the default, shown from `info` up), and tool
start/finish diagnostics are `debug`/`tool`. Background-task chatter and
bash-echo reassignment follow in #2118's follow-up.

## Line pattern

Without `logging.format` the sinks keep today's shapes: fa.log lines are
`<ISO timestamp> <level> <message>` (the level tag is the only addition),
console lines render their raw message. With a format set, the
placeholders `{time} {elapsed} {sid} {level} {cat} {msg}` render on both
sinks; `timeFormat` supports `HH`, `mm`, `ss`, `SSS`; unknown
placeholders stay literal.

## Redaction

Every rendered line on every sink passes the redaction pipeline
(`lib/src/redact/`) — including `trace` payloads. Silencing is cheap:
filtering happens before formatting and before the append chain.

## Per-request usage diagnostics

Set `FA_USAGE_TRACE=1` to emit compact diagnostics at usage-segment close.
The default is off; `fa-tokens:` and `usage.json` keep their existing
formats. Diagnostics go to `fa.log` and, for headless runs, stderr (and
thus `--log-file`/`FA_LOG_FILE`); stdout and structured wires stay unchanged.
Normal file logging filters still apply.

Entries are in session-chain order, prefixed with `sid=<session-id>`:

- `usage_request: {"t":"...","in":N,"out":N,"cr":N,"source":"reported"}`:
  the fold's per-request input, output and cache-read counts. `t` is the
  request-summary timestamp (or the assistant record timestamp if no
  summary exists); it can be null for older records. `source` is
  `estimated` when usage was missing or a request did not finalize.
  Summing these counts matches the segment's `fa-tokens:` line.
- `tool_result:<name>:<bytes>`: UTF-8 bytes of the persisted result's
  JSON-encoded content blocks, including empty, error, and image results.
  The name is percent-encoded; result content is never logged. This is
  a content-size proxy, not provider wire bytes or a token count.

These are reconstructed from the same persisted records as the ledger,
only for the segment closed by this process. They are emitted at close,
not live: an ungraceful kill may prevent emission, although the chain can
still be rebuilt while it survives. The byte-size overhead depends on the
session; small sessions can exceed 5%.
