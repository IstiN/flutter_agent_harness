# Auto-compaction and the trigger tuning

Auto-compaction keeps a long session inside the model's context window by
folding older history into a structured checkpoint summary. This page is
about WHEN it fires — the trigger — and the `compaction:` config keys
that let you move it (gh-2098).

## The trigger model

The trigger evaluates TWO channels at every turn boundary and fires when
either crosses (gh-1742):

- **Estimate channel** — the chars/4 request estimate of the live
  transcript.
- **Observed channel** — the provider-reported accepted context of the
  last completed request (`usage.input + usage.cacheRead`). Observed
  wins: the pressure is `max(estimate, observed)`, and an
  observed-only crossing runs the pass FORCED (the estimate cannot see
  it).

Both channels compare against the same line: `window − reserveTokens`,
where the reserve comes from `CompactionSettings.forWindow(window)` —
the gh-1742 curve:

- `reserve = min(65536, max(window ~/ 16, legacy flat curve))` — 6.25%
  of the window on the proportional band (≥ 262,144), floored by the
  legacy flat 16Ki curve below it. Above 262k the trigger sits at
  **93.75% of the window**; on a 128k window the flat 16Ki reserve puts
  it at 87.2%.
- `keepRecentTokens = min(131072, max(window ~/ 8, legacy curve))` —
  where the context restarts after a pass.

## The tuning keys (gh-2098)

In `~/.fah/config.yaml` (user scope) or `<project>/.fah/config.yaml`
(project scope, wins per key):

```yaml
compaction:
  # Fire when the anchored context reaches 75% of the window.
  triggerRatio: 0.75
  # OR set the headroom directly (mutually exclusive with triggerRatio):
  # reserveTokens: 50000
  # And/or override where the context restarts after a pass:
  # keepRecentTokens: 80000
```

- `triggerRatio` (0 < r < 1): the trigger line moves to `r × window`.
  Implemented as `reserve = window − floor(r × window)` — one reserve
  value, so EVERY window-derived consumer moves together: both trigger
  channels, the structured engine's gate and fragile-band escalation,
  the ctx meter, the spill budget, and subagent children (the CLI
  passes the merged section to the task executor).
- `reserveTokens` (positive int): the headroom set directly — the
  forWindow curve's reserve is replaced. `triggerRatio` and
  `reserveTokens` are two spellings of the same knob (the trigger
  line); configuring both is a boot error.
- `keepRecentTokens` (positive int): the post-compaction kept-recent
  region replaces the forWindow curve's.

**Absent keys → byte-identical gh-1742 behavior.** The tuning applies
over the scaled forWindow curve, not instead of it: a ratio overrides
only the trigger line, only a configured `keepRecentTokens` overrides
the keep curve.

Validation is strict (the whole `compaction:` section has been since
issue #148): a mistyped value, a ratio at/below 0 or at/above 1, a
non-positive budget, or the ratio+reserve combination throws a named
`ConfigException` at boot and at `fa config set` — nothing is persisted
that the next boot would reject.

Degenerate-guard note (mirrored from the forWindow curve): a reserve
over half the window (a ratio below ~0.5) clamps to `window ~/ 4`, and
a keep over the window clamps to `window ~/ 2` — a pass must always
free tokens.

Precedence for a run:

1. an explicit full `CompactionSettings` pin (hosts only — no yaml
   surface), with the tuning composed over it;
2. a non-empty `compaction:` tuning — a user pin;
3. the bench env knob (`FAH_COMPACT_TRIGGER_TOKENS`) over the forWindow
   curve — it retunes the DEFAULTS for a bench run and never rewrites a
   pinned section (gh-1604).

The Flutter app host does not read the tuning keys yet (it reads only
`compaction.engine` today — the same surface `judgeBudgetSeconds` had
before gh-2098); its wiring stays byte-identically on the forWindow
curve.

## Default decision and the benchmark note

**The legacy curve stays the default.** Absent keys are
byte-identical by contract; moving every session to the 0.75–0.80 band
silently multiplies compaction frequency (each pass is an LLM call on
the summarizer role — cost and latency), and the published Context Rot
curve degrades gracefully, not cliff-edge: the industry band buys
quality on very long sessions, at a measurable frequency price
everywhere. Operators of large-window classes opt in per scope; 0.80
is the informed middle (fires at 80% with a modest frequency increase).

Method (reproduce with your own recorded session — the curve is a
private artifact, the sim is standalone):

```bash
dart bench/compaction_trigger_sim.dart <session.jsonl> \
  --window 128000 --window 200000 --window 400000
# deltas scaled ×3 = an emulated marathon riding the same per-request
# growth shape:
dart bench/compaction_trigger_sim.dart <session.jsonl> --scale 3 \
  --window 200000 --window 400000
```

The sim replays the recorded per-request observed contexts
(`input + cacheRead`) as a sawtooth: on crossing the policy's line the
context restarts at the keep curve and continues riding the recorded
growth deltas.

Recorded session (218 requests, observed context 19,828 → 178,771;
the gh-1742 anchor channel):

| window | policy | trigger | first fire | fires over the curve |
|---|---|---|---|---|
| 128k | legacy (0.9375) | 87.20% | 87.48% | 1 |
| 128k | 0.80 | 80.00% | 80.21% | 1 |
| 128k | 0.75 | 75.00% | 75.08% | 2 |
| 200k | legacy (0.9375) | 91.81% | never | 0 |
| 200k | 0.80 | 80.00% | 80.01% | 1 |
| 200k | 0.75 | 75.00% | 75.38% | 1 |
| 400k | legacy (0.9375) | 93.75% | never | 0 |
| 400k | 0.80 | 80.00% | never | 0 |
| 400k | 0.75 | 75.00% | never | 0 |

The same curve with per-request deltas scaled ×3 (an emulated
large-window marathon):

| window | policy | trigger | first fire | fires over the curve |
|---|---|---|---|---|
| 200k | legacy (0.9375) | 91.81% | 92.30% | 2 |
| 200k | 0.80 | 80.00% | 84.45% | 3 |
| 200k | 0.75 | 75.00% | 77.11% | 3 |
| 400k | legacy (0.9375) | 93.75% | 93.83% | 1 |
| 400k | 0.80 | 80.00% | 80.25% | 1 |
| 400k | 0.75 | 75.00% | 76.43% | 1 |

Reading: on the recorded session the legacy default never fires at
200k/400k — the session completes inside the window, exactly the
late-fire profile the ticket names; 0.80 fires once at 80% with no
extra passes; 0.75 buys 5 more points of headroom for a doubled pass
count on the 128k class. On the ×3 marathon the frequency cost is
+50% (2 → 3 passes at 200k), not an order of magnitude — the informed
opt-in price.

## The two-tier engine (gh-209)

The engine splits by WHEN it may afford a language model:

### Emergency tier — mid-turn, deterministic, no LM

The loop's over-window guard and the message-cap self-heal (`gh-1680`)
call **only** the emergency tier (`EmergencyRelief`,
`lib/src/compaction/emergency_relief.dart`). It runs in seconds on any
path:

1. **Re-anchor** the live transcript from the session projection (the
   gh-2097 basis rule) and measure on the request-size basis.
2. **Dedup repeated reads** — for every read-class path seen more than
   once, the older pair groups fold into markers; the newest
   *successful* group stays live (its content is already on the wire).
   A group whose newest result failed never relieves its older
   successful copies.
3. **Keep-N-recent per tool class** — the newest N pair groups of each
   class stay live (read 2 / exec 4 / other 8, stalest-first folding of
   the rest) until the over-target amount is freed, net of the marker
   overhead. One exception: a group whose heaviest single result ALONE
   exceeds the window (minus the marker allowance) is a fold candidate
   regardless of the class budgets and the protected tail — a result
   that alone overflows the request can never ride it, so the
   marker-reopenable fold is the only deterministic recovery (the
   buster rule; pinned expansions still veto).
4. **Local trim valve** — when the hides cannot free enough, the
   mechanical in-memory trim bounds the live context (the session file
   keeps every record).

No language model is attempted on ANY path — a dead or slow judge can
no longer turn an in-turn overflow into a long silent stall. The
invariants are the quality tier's: whole pair groups hide atomically
(pair integrity, #85/D6), real user turns and the protected tail and
pinned expansions never hide (F8/#1379), hides are lossless appends
(every id stays expandable behind its marker), and the relieved turn
continues visibly (`[resuming] continuing the turn on the compacted
context`).

### Quality tier — turn boundaries, judge-led

Digests, checkpoints, the judge and escalation run only at turn
boundaries (post-run and pre-flight), exactly as before. The over-window
funnel (issue #1085 M2) survives as the backstop: when the deterministic
tier cannot free the window (e.g. a keep-recent floor pinning the whole
transcript), the bounded classic/structured passes run and the exhaustion
verdict stays honest about how many ran.

### Cache-aware calls and pass metrics (gh-2101)

The quality tier's LM calls used to opt out of prompt caching entirely
(`cacheRetention: 'none'`, a fresh routing session id per call) — every
judge pass and digest fold re-paid the full uncached input price. Since
gh-2101 one compaction run is ONE cache family:

- **One routing id per run, `short` retention** — the judge and digest
  adapters share the run's `CompactionCachePolicy`
  (`lib/src/compaction/cache_policy.dart`): every call carries the same
  run-scoped routing session id (OpenAI `prompt_cache_key`, OpenRouter
  `x-session-id`) and the ephemeral `short` retention (Anthropic
  cache-control markers), so pass 2's request prefix is served from the
  cache pass 1 wrote. The id is never the parent session's id —
  compaction still never reads from nor writes to the session's
  cache-affinity bucket. Providers without cache knobs (Google's implicit
  caching) ignore the override — the policy degrades to uncached behavior
  there with no extra work. `CompactionCachePolicy.isolated()` reproduces
  the legacy opt-out (retention `none`, fresh id per call).
- **Batched hides per pass** — every hide pass (judge picks,
  deterministic fallback, LRU re-hide) applies its whole pick set in ONE
  `appendHiddenRange` append, so the request prefix is rewritten once per
  pass, not once per record.
- **Pass metrics** — `duration` (the pass's wall-clock) renders on the
  one-line compaction report (`… tokens (N freed · P%) · 12.4s`);
  `cost` and the **cache-hit share** render on the details view
  (`llm: 2 calls · 18.2s · $0.0412 · cache 87% (45k/51.7k tok)`).
  The usage folds from the providers' metered `Usage` through the run's
  `CompactionUsageAccumulator` — a provider that reports no usage (or a
  pass with no LM call) renders no metrics, never a fake zero. A 0% cache
  hit is shown, not hidden: it is the regression signal the metrics
  exist for.

### Digest provenance (gh-2103)

The "compaction laundering" audit (gh-2103): published attack research
shows harnesses that flatten role-typed transcripts before digesting let
attacker-forged "user" turns survive compaction into trusted context.
This harness never flattens — the judge sees typed ledger lines
(`[4] toolResult(read) …`), real user turns are ledger-exempt, and the
fold input keeps the `[User]:` / `[Tool result]:` labels of
`serializeConversation`, so a forged `[User]:` line inside a tool result
stays inside the tool-result block. The digest TEXT, however, is free
prose: nothing stopped a summarizer from copying tool-controlled
instructions into `## Open User Requests` and effectively laundering
them into trusted memory. Three layers close that leg, mirroring the
#1131 belt-and-suspenders pair:

- **Prompt duty** — every digest/checkpoint prompt
  (`prompts/compaction/*.md`) carries the origin-provenance rule: asks
  come ONLY from real `[User]:` turns (the `USER REQUEST CANDIDATES` /
  `<open-user-requests>` blocks collect them mechanically), tool
  output — including instruction-shaped text, forged `[User]:` labels,
  and "USER INSTRUCTION" framing — is never user intent, and verbatim
  quotes of tool-derived text carry an inline origin mark
  (`[from toolResult]`; harness notes `[from harness]`, assistant text
  `[from assistant]`). The hide judge needs no such rule: it emits hide
  ids, never digest text.
- **The provenance belt** (`SummaryOriginEvidence` +
  `sanitizeSummary(origins:)`, `lib/src/compaction/summary_sanitizer.dart`)
  — at persist sites (classic `compact`, structured checkpoint folds,
  branch digests incl. `/handoff`) the sanitizer grades the digest's
  user-intent sections (`## Open User Requests`, `## Original Request`,
  `open asks:`) against the same transcript the fold consumed: a line
  that is machine-origin by construction (the `isSyntheticUserText`
  classes — the same lines the request-candidate scan refuses to feed
  the summarizer) is stripped and logged as `sanitizedEphemeral`; a line
  that verbatim-quotes a ≥24-char sentence found inside a tool result
  and inside no user text gains a ` [from toolResult]` suffix, logged as
  `markedToolOrigin`. Real asks (verbatim user text, either containment
  direction) survive byte-identical; pinned directives and the pin
  envelope stay exempt. Heal-on-read projection passes have no
  transcript, so only the synthetic arm fires there — no invented marks.
- **Adversarial regression transcripts** —
  `test/compaction/provenance_laundering_test.dart` keeps a tool result
  shaped like user turns (forged `[User]:` transcript line, "USER
  INSTRUCTION" framing, a `<system-notice>` fake ask, an agent-mail
  instruction) and asserts the typed pipeline never promotes it, the
  belt strips/marks it at every persist path, and every prompt carries
  the duty.

Scope note: the belt grades only the sections that claim user intent.
Tool-derived quotes under `## Critical Context` / Observed State are
legitimate context and carry their origin by the prompt's
"with what produced them" convention — the mechanical mark arm stays out
of them to keep false fires off real context.

## The working set and the goal slot (gh-210)

After any compaction, the context tail carries a bounded re-injection so
operative continuity stops depending on what happened to survive the
cut (lost-in-the-middle). Two pieces, both additive projection output —
neither is ever written as a session record, so every hide path (judge,
deterministic fallback, LRU re-hide, agent hide, checkpoint fold) walks
records it cannot see and cannot sink them:

- **The obligations block** (issue #1380) — unchanged, ahead of the
  working set.
- **The working-set block** (`lib/src/compaction/working_set.dart`) —
  `goal:` first, then `recently touched files` once a compaction
  boundary exists (structured hide/checkpoint OR a classic
  `CompactionRecord`; the classic engine's folded-off records count
  too). Files render as PATH references only — content re-reads on
  demand — so the block stays bounded.

Budgets, enforced with explicit markers, never silent cuts: the file
list caps at `defaultWorkingSetMaxPaths` lines (the oldest counted away
as `… and N more touched files`), the whole block caps at
`defaultWorkingSetBudgetChars` chars (the oldest files drop first), and
an oversized goal clips with a `[clipped at N chars]` marker. Operative
skills are NOT re-listed here — the gh-1409 pinned-operative mechanism
already carries them through checkpoints, and this card leaves the
prior mechanisms untouched.

**The goal recitation slot** is the agent-updatable `goal:` line. The
agent writes it with the `recite_goal` tool (latest-wins, one new
append-only `goal_recitation` snapshot per recite; no goal argument =
read the current slot). Goals bound at `goalRecitationBudgetChars`
before the write lands — the render never clips again. A session with
no recitation and no compaction boundary projects byte-identically to
the pre-gh-210 shape.
