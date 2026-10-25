# Session hygiene: keeping long-lived sessions healthy

Long-running `fa` sessions grow an append-only JSONL ledger. Most of that
growth is not conversation — it is hidden bookkeeping records
(`model_request_summary` captures, job/subagent registry snapshots). This
page is the playbook for noticing growth early and reclaiming it safely.
Nothing here rewrites history silently: every reclaim is explicit
(a command you run) or config opt-in (a flag you set).

## Watch the size before it hurts

- `fa session info [<sessionId>] [--json]` — the size/records breakdown:
  total bytes, records by kind, every custom ledger with its exact byte
  weight, what a vacuum would reclaim, and what `fa session repair`
  would drop. One streaming pass; progress on stderr; Ctrl+C cancels
  into a partial report.
- Resume, `fa trajectory view|cost|inspect|export`, `session_search`, and
  `fa session info` warn once when a session file exceeds **500 MB**
  (exact size + the escapes below). The warning means the ledger — not
  your conversation — has grown.

## What the ledgers cost

- `model_request_summary` — one per LLM call. Bounded by default
  (≤ ~20 KB/record: counts, sizes, per-message stubs for the newest
  tail, a `droppedMessages` aggregate); the full per-message detail
  lives in `.fah/trajectories/<sid>/requests/` under a TTL/rotation
  budget. Legacy records (pre-bounding) carry ~200 KB–300 KB each — the
  dominant cost on old marathons. Opt out of the spill (inline
  persistence, debugging only): `trajectory.requestBlobs: false`.
- `shell_job_registry` / `subagent_registry` / `obligations_ledger` —
  latest-snapshot-wins: every reader consumes only the newest snapshot,
  but older snapshots accumulate (10k+ snapshots on multi-week
  sessions). Latest is what survives a vacuum; the rest is reclaimable.

## Escapes, cheapest first

1. **Vacuum dead snapshots at resume (opt-in).** Set
   `sessions.vacuumLedgers: true` in `~/.fah/config.yaml`. Every session
   open drops the superseded registry snapshots (keep-latest) through
   the same surgery as `fa session repair` — request summaries and
   trajectory blobs are never touched by the resume vacuum. Skips live
   sessions; the original bytes stay at `<file>.bak`.
2. **`fa session repair <sessionId> [--dry-run]`** — the explicit deep
   clean: keep-latest on the registries PLUS drop of the
   `model_request_summary`/trajectory blob ledgers. Dry-run first: the
   plan prints the exact per-type reclaim. Refuses live sessions;
   atomic swap; original at `<file>.bak`.
3. **Start fresh / branch.** When a session's context itself is the
   bloat (compaction has run many times), a new session (or a branch
   fork of the current one) is the clean reset. Compaction frees
   context tokens, not bytes.

## When to start fresh

- `fa session info` shows total bytes growing again days after a
  vacuum — the ledger tail (messages + post-bounding summaries) is now
  the cost, and no reclaim targets it.
- Resume feels slow despite a vacuumed ledger (windowed resume reads
  the tail; if even that is heavy, the session's working set is the
  problem).
- You no longer need the history: fork a branch for continuity, leave
  the old session archived.

## Measured shape (issue #1882)

A 53-day session reached 2.89 GB / 41,557 records: 61%
`model_request_summary`, 26%+10% job/subagent registries, ~2% actual
messages. Post-fixing: new summaries are bounded ≤ ~20 KB (the
request-side detail spills to blob files), and a vacuum on a 2.06 GB
fixture reclaims ~100% of the ledger bytes in ~5 s while the windowed
resume stays sub-100 ms at any size.
