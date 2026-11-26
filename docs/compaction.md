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

### Soft window and honest overhead (gh-2411)

The context window is a SOFT target — a slight overrun is accepted; an
invisible user turn is not. Three rules, one basis:

- **The newest real user turn never drops.** The turn and its pair
  group are excluded from the checkpoint range and from every hide
  candidate (real user text was already exempt). When a mechanical cut
  has to land BEHIND the turn — the local trim valve's budget walk, or
  a classic cut that splits the turn — the turn is CARRIED: the valve
  re-homes it verbatim right after its `[context trimmed]` marker, and
  the classic summary opens with the ask verbatim. A hard floor at the
  turn was tried and rejected: it leaves a long tool-using turn with
  nothing trimmable and kills the funnel backstop
  (`lib/src/compaction/newest_user_turn.dart`).
- **The overhead is priced as the provider bills it.** Every request
  carries a fixed overhead — the system prompt and the tool schemas.
  It is priced at 2.5 chars/token, not the transcript's 4 (measured on
  the gh-2411 session: 65,561 overhead chars — 12,105 of system prompt
  plus 34 tool schemas — were billed 24,126 provider tokens, 2.72
  chars/token, where chars/4 priced 16,407, 32% under).
  Per session the first valid provider `usage.input` calibrates the
  estimate (`OverheadCalibration`, ratio clamped to [0.6, 4.0];
  re-derived at resume from the last valid provider report anywhere in
  the session — gh-2411 follow-up #5c) — it may LOWER an over-reading heuristic too (the
  owner's live test: glm-5.3-flash billed 15,792 tokens where the
  heuristic read 24,348, ratio 0.65) — and the ctx meter, the loop's
  over-window guard and the compaction trigger all read that same
  basis (`estimateRequestTokens`). The heuristic itself is a
  per-provider average: before the first anchor lands the meter can be
  off by that ratio.
- **Soft window — no trim thrash, no unbounded growth.** When
  `overhead + newest user turn ≥ window − reserve`, no trim can ever
  reach the trigger. WHILE THE ESTIMATE IS UNDER THE WINDOW nothing is
  trimmed: automatic compaction is skipped and the session is warned
  ONCE per distinct warning text (a resumed session does not repeat it
  at its first prompt): `context window {window} cannot take a trim below its trigger
  ≈{overhead} tokens (estimated from the system prompt + tool schemas)
  — raising the window or disabling tools is the only fix; automatic
  compaction is skipped while the context stays under the window`. AT OR OVER THE WINDOW the
  request is simply over the window: the automatic pass is the
  hide-only, LM-free relief (the same one the loop guard runs — the
  newest user turn is still carried verbatim), a pass that frees
  nothing re-runs only after the transcript changed, and the loop's
  over-window guard keeps its stop. ONE predicate decides both sides —
  `softWindowSkip`: the regime AND `estimate < window`
  (`lib/src/compaction/soft_window.dart`). Skipping over the window as
  well was the first cut; the owner's live test grew a session to 114%
  with no pass ever running.

#### Anchored at load/resume; unmeasured estimates never cut or stop (gh-2411 follow-up #5)

The overhead calibration is taken at LOAD/RESUME too: a transcript that
carries a vouchable provider usage report (after its newest compaction
boundary, or on a branch complete to its root) anchors the estimate the
moment it is loaded, so a restarted session is priced by the provider's
own number on its very first request.

**Resume with a checkpoint summary (gh-2411 follow-up #5e).** The resume
parity trim stands down while a checkpoint summary is resident: the walk
opens the window at the newest durable boundary, the request opens with
its summary and then only the raw tail the summary does not cover, and
the local-trim valve pins that summary like the newest user turn. An
over-trigger first request goes out as loaded and takes the existing
first-turn pre-flight compaction path. The resume tail line and the
`resume summary` diagnostic name the summary's record.

**The stop that compacts is not an error (gh-2411 follow-up #5e, E2).** A
turn the loop stops so compaction can run and continue is logged `turn
end … stop=compacting (continuation pending)`; `run end` is written once,
at the true end of the run (the continuation's own run). A stop with no
continuation — or one whose continuation did not complete the turn — keeps
the honest `stop=error`. Internal stop reasons and persisted records are
unchanged; only the log tells the truth.

**The hand-over knows how the run ended (E3a).** The hand-over request is
the last request's context, which never carries the final assistant reply;
the instruction therefore states it: `Run status: the final assistant reply
WAS delivered — that turn is answered, not pending`, or that the newest
user turn has no delivered reply, or that no claim can be made (a hand-over
built without a transcript).

The resume boundary walk is a MEASUREMENT or it is nothing. A measured
session keeps today's parity budget (`window − calibrated overhead −
reserve`) — the walk stops at it and trims record-granularly. An
unmeasured one walks with NO budget: to the newest compaction boundary or
the file head — only a boundary (durable, visible) may limit what loads.
A budget of zero (the window below overhead + reserve) is no budget
either: its one-record tail dropped the newest user turn. Whenever the
loaded projection is a tail of the file, one line says so, in the
transcript and on screen: `[resume] loaded the last K message(s) of the
session (N older record(s) left on disk …; ≈T tokens, estimate)`.

A resume right after a durable checkpoint is MEASURED too (gh-2411
follow-up #5c): the overhead is a property of the system prompt + the
tool schemas, not of the folded history, so the calibration is derived
from the last valid provider report anywhere in the session — a bounded
backward walk pages older records until that reply and the boundary (or
the file head) that opens its context are resident. Without it the
resume read `budget=none (unmeasured: estimate only)`, fell back into
the soft-window regime on the raw heuristic and trimmed the context to
three messages against a provider truth of 15,310. Two more invariants
of the same round: the budget trim never opens the kept tail on an
assistant or tool message (`projectedBranchBudgetCut` →
`_openOnUserTurn`), and the tail line's figure is overhead + the
estimated tail — the number the first request is metered at, not the
overhead alone.

Until the provider has answered in a session and nothing is measured, no
in-memory cut runs on the heuristic alone — not the boot cap, not the
soft-window relief — and the loop's over-window guard does not stop: the
request goes out, the answer anchors the session, a real overflow takes
the existing overflow path. A calibration pinned on the 4x ceiling is no
measurement either — the guard ignores it. Every in-memory cut opens the
request on a user turn (never on an assistant or tool fragment), leaves a
`context_trim_receipt` record in the session and a diagnostic line, and
every heuristic number the host prints carries an explicit `≈`/estimate
marker.

A hand-over reply whose transfer carries no `## Open User Requests`
heading gets ONE corrective retry (the retry names the section and
quotes the defective reply); a second miss keeps the failure.

#### First-anchor overhead, bounded resume walk, honest relief (gh-241 follow-up #5d)

- **The overhead anchor is the session's FIRST valid provider report** — the
  overhead-dominated request — not the tail-heavy reply after the newest
  boundary (`resume calibration source=first|pre-boundary|post-boundary
  anchor=<id> ratio=x<N>` is always logged). At the owner's 25k window the
  two reports differ (x0.66 vs x0.82 → overhead ≈19.5k vs ≈15.7k tokens).
- **An unbudgeted resume walk (`budget=none`) stops at the newest durable
  boundary** — a classic compaction or a structured `compact_checkpoint` —
  instead of paging to the file head. Everything file-older than that
  boundary cluster stays on disk: a resume never resurrects history an
  earlier cut removed from the live context.
- **The newest REAL user turn survives every in-memory relief.** Projection
  markers the engine writes as user-role messages (hidden/ckpt markers,
  `[expand N-M]` pointers, the local-trim marker) are machine content and
  are never taken for it.
- **A context stop keeps its promise.** After the guard's stop the
  under-window paths run first (the regime's hide-only relief, the unforced
  pass); when they yield nothing the `auto-compacting…` pass runs FORCED —
  never over a disabled engine. In the soft-window regime an over-window
  request with relief spent is SENT (the provider is the real limit): a
  read-only turn no longer ends in `stop=error`.
- **Notices say what happened.** "Relieved" when no summary pass ran; a
  `context_trim_receipt` only when content was actually hidden or trimmed;
  the resume tail line prints overhead plus the estimated tail on the
  calibrated basis once a report exists. The estimator's density under-read
  for non-Latin text is a separate follow-up.

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

### Compaction 2.0 v2.1 — the merged hand-over call (gh-2394)

The quality tier's post-run fold is ONE call on the **session's own
model** that reads the last main request exactly as it was sent and
replies with a hide list plus a hand-over text ("merged" mode). The
judge-led checkpoint ladder stays what it was for the `standalone` mode
(a host that wires a separate smol digest role) and for every session
without a request snapshot; the classic engine is untouched. Which mode
runs is decided by a pure table, never by an outcome
(`lib/src/compaction/compaction_mode.dart`):

| engine       | S0 valid for the session model | separate digest role | mode        |
|--------------|--------------------------------|----------------------|-------------|
| classic      | –                              | –                    | `classic`   |
| structured   | yes                            | no                   | `merged`    |
| structured   | no                             | –                    | `standalone`|
| structured   | yes                            | yes                  | `standalone`|

- **Record tags (the epoch rule).** Under the structured engine every
  request prefixes each projected record with its file alias `m<N> `
  (`record_tag.dart`); the alias index is built over the whole chain at
  load, so the first request after a resume tags every visible record.
  The live edge past the last record is UNTAGGED — a non-record (the
  continue nudge, the working-set tail) never borrows a predicted alias.
  Tags live only on the wire: `stripRecordTags` removes them before any
  persisted text, and the CLI/Flutter tests compare hosts tag-for-tag.
- **S0 — the request snapshot.** The agent loop captures each main
  request as sent (`request_snapshot.dart`: messages COPY, system
  prompt, tools, the alias index, the model, the routing). A snapshot is
  valid until the model changes or a host/compaction run appends
  records (`Agent.invalidateRequestSnapshot`). The hand-over call sends
  S0's prefix byte-for-byte with the request shape in the zone
  (`StreamCacheRouting`: NULL tool choice, the session model's
  `maxTokens`, Anthropic's history breakpoint on the last user turn,
  Copilot's `maxTokens`; pinning Copilot's `x-initiator` to S0 is a
  listed gap — the snapshot carries no initiator yet), so the bucket the
  main request just warmed
  is read from cache — the hand-over instruction is the ONLY delta,
  appended as the last user message (`prompts/compaction/hand_over.md`,
  rendered with the pressure, the fold range aliases, the mechanical
  `<open-user-requests>` block, the pinned-operative lines and the
  folded-checkpoint blocks).
- **The reply and what the engine does with it (AC7).** `N`/`N-M` lines
  with an optional label are hide proposals OUTSIDE the fold range; a
  `-` line separates them from the hand-over text. The engine disposes
  the proposals (`structured/hand_over_dispose.dart`): a tool pair snaps
  to its whole group; user turns are never hidden; an alias unknown on
  the SNAPSHOT index, a checkpoint/fold record, a record inside the fold
  range or already hidden/covered, and the protected tail are ignored
  (buckets `U/F/C/X/T/S`, rendered as `hide list 1 snapped · 1 exempt`).
  A hide range is ONE `hidden_range` record with `consolidated: true`
  and the sanitized labels (`labels`, per carrier: one line, ≤ 48 chars,
  no second person, no imperative, never a message). The hand-over text
  is persisted as a tail-layout `compact_checkpoint` whose `## Open User
  Requests` section must carry every request of the mechanical block
  verbatim — otherwise the run FAILS and nothing is appended. The text
  goes through the summary sanitizer with the S0 origin evidence and the
  pinned lines protected (gh-2103, gh-1409).
- **Markers (AC9).** A consolidated range renders ONE marker at its
  carrier — `<label> [expand 6-7]` — the fold pointer `[expand 2-5]`
  sits untagged where the range's first record rendered, the transfer
  record renders at its own position with the tagged hidden index
  (`m4 tool_result·…`). `compact_expand` reopens both kinds;
  `isCompactionMarkerText` resolves the old and the new forms.
- **No fallbacks (AC4).** The call's robustness ladder is nudge on a
  tool-call reply, the existing transient retry, and ONE retry at twice
  the output budget on a `length` stop; an exhausted ladder appends
  NOTHING and reports a loud failed pass (`hand-over call failed …`) —
  the merged path never reaches the hide judge, the digest or the
  classic prefix compactor (the budget kill keeps only the mechanical
  local trim, which needs no endpoint). The main request then proceeds
  under the existing over-window guards. The hide judge is not removed
  by this PR: it still serves the `standalone` ladder.
- **Trigger (AC11).** Pre-flight stays hard-only (`shouldCompact`). The
  POST-RUN call fires on the soft line: `compaction.softRatio` × window
  (default: the hard line minus 5 % of the window), muted by a
  hysteresis of `compaction.handOver.hysteresisTurns` user turns
  (default 3) after any run — the hard line is never muted. A prompt
  arriving while the post-run call is in flight waits on the
  `compacting` gate (`CompactingGate`), one run at a time.
- **Keys.** `compaction.softRatio` (0 < r < 1), `compaction.handOver.
  maxTokens` (positive int, default 8192 — the call's output budget),
  `compaction.handOver.hysteresisTurns` (positive int). Strict like the
  other tuning keys: an invalid value is a config error, never ignored.
- **Report.** The details report carries `hand-over: merged · bucket
  warm · calls 1 · cache 92% · hide list 1 snapped · nudges 0 · budget
  retries 0 · transfer text`; the one-line default names the engine
  `structured·hand-over`.
- **Old sessions (AC20).** No migration, no re-encode, no tag backfill.
  Records written before 2.1 load unchanged (the new fields are
  additive and only written when set), legacy checkpoints render in
  place exactly as before, the first compaction after a resume is a
  merged call over the old chain, and `session_search`, `/handoff` and
  `fa session list` read old and new records alike. The file is only
  ever appended to (byte-prefix).

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

## The working set (gh-2423) and the honest notices

After any compaction, the context tail carries a bounded re-injection so
operative continuity stops depending on what happened to survive the
cut (lost-in-the-middle). Two pieces, both additive projection output —
neither is ever written as a session record, so every hide path (judge,
deterministic fallback, LRU re-hide, agent hide, checkpoint fold) walks
records it cannot see and cannot sink them:

- **The obligations block** (issue #1380; reconciliation per #2384) —
  unchanged, ahead of the working set. Fresh open entries itemize as
  before; a pending-wait whose scheduled message fired (a `delivered`
  receipt on the trail) auto-closes at the next ledger pass (boot or
  flush), open entries past `obligationStaleAfterDays` age to `stale`,
  and aged entries collapse into ONE summary line
  (`… and N aged obligations — run ledger reconciliation`) instead of
  riding as itemized `[open]` quotes — the 117-entry zombie class cost
  ~18k tokens per compaction before #2384. On every snapshot append the
  file's latest snapshot wins for entries the writer did not mutate
  since seed, so an external cleanup is never buried by a stale
  in-memory re-assert.
- **The recently-touched-files block**
  (`lib/src/compaction/working_set.dart`) — `recently touched files`
  once a compaction boundary exists (structured hide/checkpoint OR a
  classic `CompactionRecord`; the classic engine's folded-off records
  count too). Files render as PATH references only — content re-reads on
  demand — so the block stays bounded. It caps at
  `defaultWorkingSetMaxPaths` lines (the oldest counted away as
  `… and N more touched files`) and `defaultWorkingSetBudgetChars` chars
  (the oldest files drop first) — explicit markers, never silent cuts.

Operative skills are NOT re-listed here — the gh-1409 pinned-operative
mechanism already carries them through checkpoints.

### The agent's working set — `working_set(text)` (issue #2423, C1)

The audit behind #2423: a hide-only compaction freed 131k tokens and the
worker asked for a fresh one 76 s later "near my context limit again",
on a 54k context — it could not see what it had decided, what was red,
what came next. The working set is the agent's OWN answer to that: the
short status it keeps for its next request — decisions made, the red
list / never-do, next steps, rules to keep. Notes, not instructions to
the harness, and never a place for secrets.

- **Surface.** The `working_set` tool (pure SDK, `lib/src/tools/
  working_set_tool.dart`) is registered for EVERY agent on every host
  and every child agent — it needs no host capability. `working_set(text)`
  creates or replaces; the newest write wins; `working_set("")` clears.
  It replaces gh-210's host-only `recite_goal` (retired without an
  alias): a legacy `goal_recitation` snapshot still renders as the
  working-set text until a `working_set` record exists on the branch.
- **Storage.** An append-only `custom` record (`working_set`) in the
  agent's OWN session file — never the orchestrator's or the parent's.
  Resume and a crash restart re-read it from the file (latest wins).
  The text passes the redaction pipeline on write; the tool result
  reports the stored size (`working set saved: N chars — pinned in every
  request, survives compaction`) or a refusal.
- **Cap.** `workingSetMaxChars` (4096). Longer text is REFUSED, not
  clipped: `working set NOT saved: … over the 4096-char cap — shorten it
  and call again (the previous working set stays pinned)`.
- **Injection.** The newest working set rides the SYSTEM channel of
  every request — the `<working-set source="agent" updated="HH:MM">`
  block at the very tail of the system prompt (`AgentLoopConfig.
  workingSetProvider`, `lib/src/agent/agent_loop.dart`). It is not a
  transcript record, so no hide, fold, trim or summary path can drop it
  by construction; a session with no working set projects byte-
  identically to the pre-gh-2423 shape. The text is DATA: it never
  grants an approval, never changes a tool tier and never feeds the
  approval gate (`test/approval/working_set_independence_test.dart`).
- **Discovery.** Two generated prompt includes ride the mode prompt on
  every host (`prompts/compaction/working_set.md` — what the working set
  is for, when to update it, that it is capped and not for secrets;
  `prompts/compaction/context_hygiene.md` — the C7 read/test/think
  hygiene rules). An explicit `systemPrompt` override is the whole
  prompt, as with the recall contract.
- **Visibility.** The TUI prints one dim line per write (`working set
  updated (N chars)` / `working set cleared`); HEP emits a
  `working_set` frame `{chars, updated, cleared}` — never the text.

### Honest notices (issue #2423, C3)

The harness knows the estimate (X) and the one window (W); the model
cannot estimate its own context and does not need to. Two notices hand
it the harness's numbers (`lib/src/compaction/context_notices.dart`),
each a SYNTHETIC user record — the `<system-notice>` envelope, machine
content for every classifier (never a pinned user turn, never an
obligation) — that rides the agent's NEXT request as its last message:

- **Post-hide** — exactly one per hide pass that hid records:
  `compacted: N records hidden; context now ≈X/W (was ≈Y); your working
  set is pinned — continue`. With no working set yet the last clause
  reads `no working set yet — write one now with working_set(text), then
  continue`. N counts the distinct records the pass took out of the
  projection under every hide mechanism — a `hidden_range`, a structured
  `compact_checkpoint` (the records its text replaced) or a classic
  `compaction` summary boundary. A child whose run ends at that boundary
  gets the notice with its next run's first request.
- **Near-limit** — once per compaction cycle (armed at session start,
  re-armed by every hide), when the pre-request estimate reaches
  `min(0.85·W, trigger − max(2,000, 0.05·W))` (85 % of the window, always
  below the trigger with a runway) — never at or past the trigger
  itself, where the hide runs next and its own notice is the message:
  `context ≈P% (X/W): update your working set with decisions, red tests
  and next steps, then KEEP WORKING; compaction will fold older records`.

A notice is QUEUED (`Agent.queueContextNotice`), not steered: the loop
drains the queue right before it injects queued steering, so the notice
is delivered and persisted with a request the run makes anyway (a tool
continuation, the next prompt, the over-window continuation) and never
opens a model turn of its own — a steered notice landing after a run's
last boundary would be delivered as a whole extra turn, and under a low
trigger every notice would breed an answer that re-crosses the trigger.
The one exception is the over-window / message-cap relief: its retried
request is built without that injection point, so there the notice is
persisted first and mirrored into the live transcript the retry uses.

The texts never say "at the limit" / "context limit" / "out of
context" / "cannot continue" (`contextNoticeForbiddenPhrases`, pinned by
test). Every token figure is the harness's pre-request ESTIMATE on the
compaction trigger's own basis, so the texts mark it `≈` and the HEP
frame carries `estimate: true` — an exact number is shown only when a
provider reported it (none does for a request that was not sent yet);
one private seam per number (`_noticeContextWindow`,
`_noticeNumbersEstimated`) is where the shared context-usage source of
truth re-points the notices. The TUI prints each notice once, dim, as a transcript row (not a
user bubble); HEP emits a `context_notice` frame
`{kind: post-hide|near-limit, tokens, window, hidden?}` — numbers only
(see `docs/hep.md`). Children get the same texts through the task
executor (the same queued notice before their next request).
