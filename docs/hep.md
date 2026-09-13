# HEP v1 — Harness Event Protocol

The machine-readable stream `fa --output events` prints on stdout: one JSON
object per line, nothing else. It is the integration contract for
server-side supervisors (the Go backend agent driver,
[backend-agent-mode.md](backend-agent-mode.md)) that mirror UI progress,
capture tool traffic, and react to cancels — without scraping human prose.

Normative source: `lib/src/cli/hep.dart` (frame builders + `HepWriter`);
the golden tests in `test/cli/hep_test.dart` pin the exact byte shape of
every frame.

## Enabling

```
fa --output events -p "fix the tests"     # HEP v1 JSONL on stdout
fa --output events=full -p "…"            # + raw tool-call arguments
fa --version --output json                # {"version":"…","hep":"v1"}
```

In events mode stdout carries ONLY the frame stream: assistant prose
deltas are suppressed (they ride `message_delta` frames), diagnostics
(tool traces, banners, errors) keep flowing to stderr, and `--log-file`
still tees the full human trace. Every line is flushed immediately — a
supervisor tailing the pipe never waits on a buffer.

## The turn model (read this first)

A **turn is one assistant LLM round** — one model response plus the tool
calls it triggered — **NOT one user message**. A user message that runs
tools produces several rounds (model calls a tool, the result is fed
back, the model answers), so one user message yields **several terminal
frames**: one `turn_done` per round, with `turn_id` incrementing per
round. The last terminal frame of a run carries the user-visible answer.
A supervisor that treats `turn_done` as "the whole reply is ready" after
the first round will truncate multi-round runs.

Turn ids are small incrementing integers starting at 1; every frame of a
round carries the same id.

## Frame catalog

| type | fields | when |
|---|---|---|
| `hep_header` | `hep`, `fah`, `session` | Always the FIRST line. Protocol version, fah version, session id. |
| `agent_start` | `turn_id` | The run began; the first `turn_id`. Once per run, never re-emitted on later rounds. |
| `message_start` | `turn_id`, `role` | An assistant message starts (`role` is always `"assistant"`). |
| `message_delta` | `turn_id`, `delta` | A chunk of assistant TEXT. Thinking deltas are never emitted here. |
| `tool_start` | `turn_id`, `id`, `name`, `args_summary` | A tool call starts. `args_summary`: one-line `key=value` summary; `events=full` carries the raw JSON arguments instead (bounded, see Bounds). |
| `tool_delta` | `turn_id`, `id`, `update` | Partial tool output (text only; omitted while empty). |
| `turn_done` | `turn_id`, `message`, `tool_results`, `usage`, `stop_reason` | Terminal for the round. `message` is the round's assistant text (empty for tool-call-only rounds). `tool_results[]`: `{id, name, ok, text}`. `usage`: `{input, output, cost}` (cost is a number, dollars). `stop_reason`: the provider stop reason (`stop`, `toolUse`, …). |
| `turn_error` | `turn_id`, `error`, `fatal` | The round failed (provider error). `fatal` is `true` today: headless runs end the run. |
| `cancelled` | `turn_id` | The run was aborted (SIGINT/SIGTERM); exit code 130. |
| `compaction_start` / `compaction_end` | `turn_id` / `turn_id`, `tokens_freed` | A context compaction run, bracketed like a round. Pre-flight compaction allocates the id of the round it precedes, so the following `agent_start` reuses it. |

## Ordering and flush guarantees

1. `hep_header` is strictly the first stdout line; every subsequent line
   is exactly one JSON object (no blank lines, no prose).
2. Frames appear in causal order; frames of one round share its
   `turn_id`.
3. Each round ends with exactly ONE terminal frame: `turn_done`,
   `turn_error`, or `cancelled` — never a mix.
4. A run emits `agent_start` exactly once; its terminal frame is the
   last `turn_done`/`turn_error`/`cancelled` of the stream.
5. Every line is flushed to the pipe as it is emitted (no batching).

Exit codes: `0` ok, `1` provider error (the terminal frame is
`turn_error`), `130` cancelled (the terminal frame is `cancelled`).

## Bounds

A pathological tool output must not blow the supervisor's pipe:

- `tool_results[].text`: capped at 2000 chars, truncated with a
  `…(+<n> chars)` suffix.
- `args_summary` in `events=full` mode: capped at 4000 chars, same
  suffix.

## Versioning policy

- The `hep` field of `hep_header` names the protocol version; it is
  `"v1"` today. Check it on the first line and refuse unknown MAJOR
  versions.
- Within v1 the evolution is ADDITIVE ONLY: new frame types and new
  fields on existing frames may appear at any time. Consumers MUST
  ignore unknown frame types and unknown fields.
- Any breaking change (field semantics, field/type removal, ordering
  guarantees) bumps `hep` to `v2` — never mutate v1 in place.
- The `fah` field is the binary version and carries no protocol
  meaning.
