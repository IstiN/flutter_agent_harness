# Compaction 2.0 — judge research (issue #148)

Date: 2026-09-12. Goal: validate the owner ruling that pass-1 HIDE is a
cheap LLM judge call (not rules), on a REAL session.

## Setup

- Subject: a live goal-builder session (14.5 MB JSONL), first window of
  138 context records (~79k tokens, previews ≈110 chars) — mixed user asks,
  assistant text, tool calls/results (read/bash/edit/web_fetch), thinking.
- Judge: `glm-5.3-flash` via z.ai coding endpoint, temperature 0,
  `thinking: disabled` requested (partially ignored — see F4).
- Script: `research/judge_experiment.py` (ledger builder + judge call +
  validation). Run: `WINDOW=140 python3 research/judge_experiment.py <session>`.

## Findings

- **F1 — The concept works.** Both iterations returned ONLY a valid JSON
  array of ids/ranges; zero hallucinated ids across both runs. A judge
  output schema this small is reliable even for a flash-class model.
- **F2 — The decision surface is tiny.** The full ledger for ~79k tokens of
  context cost **~4.5–5k prompt tokens** (~17:1). Even WITHOUT provider-side
  prompt caching, a judge call at the edge is cheap; caching (where the
  provider supports it) is upside, not a prerequisite.
- **F3 — Judge is aggressive; prompt precision decides correctness.**
  Iteration 1 (weak prompt): 108 records, 66% freed — but it hid assistant
  TEXT conclusions and tool-call carriers with empty previews.
  Iteration 2 (tool-call previews + pair rule + conclusion protection):
  113 records, **88% freed**, emitted 17 clean CONTIGUOUS ranges
  (`["4-49","52-53","55-57",…]`) — contiguous ranges are naturally
  pair-friendlier. It still hid two large assistant-TEXT analysis messages
  ([85], [108]) — defensible (their content was already merged into the
  issue artifact being edited), but exactly the class #81 cares about.
  → The judge prompt needs an explicit "assistant-TEXT = visible answers to
  the user, hide only if their content is provably persisted elsewhere"
  clause, and the engine-side exemption list stays the hard backstop.
- **F4 — glm-5.3-flash reasons anyway.** `thinking: {type: disabled}` did
  not stop reasoning (run 2: 680 of 743 completion tokens were reasoning).
  Cost stays trivial (5.7k total tokens/call), but budget `max_tokens`
  ≥ 1500 or the answer truncates to EMPTY (run 0 with 512: empty answer —
  a real failure mode to guard: empty content ≠ empty hide list; treat as
  judge failure, hide nothing).
- **F5 — Ledger previews are the judge's eyes.** Records with empty
  previews (tool-call carriers) were hidden blindly in iteration 1. Tagging
  carriers as `assistant-TOOLCALL(names)` fixed the blind spot and made the
  pair rule enforceable by the judge itself.
- **F6 — Pair integrity needs BOTH layers.** The judge respected the pair
  rule when it could SEE pairs (iteration 2's contiguous ranges), but the
  engine must still snap ranges to pair-atomic boundaries before applying
  (D6) — a judge is a proposer, never the executor.
- **F7 — z.ai reports `cached_tokens: 0` and recalculates asynchronously**
  (owner: "всегда отдает ноль, пересчитывают потом") — caching IS expected
  to work server-side; the design still does not depend on it.

## Iterations

| run | ledger | judge output | freed | problems |
|---|---|---|---|---|
| 0 | 138 rec, weak previews | EMPTY (truncated by max_tokens=512) | 0% | reasoning ate the budget |
| 1 | 138 rec, weak previews | 108 ids | 66% | hid conclusions; blind tool-call carriers |
| 2 | 138 rec, tagged previews | 113 ids in 17 contiguous ranges | 88% | 2 borderline assistant-TEXT hides |

## Implications for the card (#148)

1. Judge prompt is a first-class artifact: version it, test it against
   golden sessions (this one included) with expected-hide ranges.
2. Engine invariants stay hard: exemption list, pair snapping (D6),
   empty-answer = no-op (never "hide everything" on judge failure).
3. Marker/ledger formats validated: numeric ids, `kind ~tokens preview`,
   contiguous ranges in output.
4. Cost model confirmed: ~5–6k tokens per judge call at the edge — orders
   of magnitude under one classic compaction summary call.


## Round 2 (2026-09-12) — judge prompt v3 + tail-window test

v3 prompt additions: ASSISTANT-TEXT RULE (visible conversation is kept
unless verifiably restated later), THINKING RULE (scratch reasoning hides
freely), PAIR RULE unchanged.

| run | window | hidden | freed | verdict |
|---|---|---|---|---|
| v3 | 1–140 (same as v2) | 115 | 89% | [85]/[108] turned out to be text+TOOLCALL records (announcement preambles, not final answers) — hiding them WITH their pairs is CORRECT; v3 keeps real assistant-TEXT conclusions |
| v3 | 1440–1580 (live tail) | 66 | 14% | desired asymmetry: conservative near the edge; hid 36 custom (huge model_request_summary records — prime targets), 34 toolResults + their call carriers (pairs intact) |

**Two new failure modes caught by the tail test (both now card requirements):**

- **F8 — The judge hid a RESOLVED user ask** ([1472] "но я хочу … allow all
  через yolo…") together with its answer [1471]. Semantically defensible
  (the work was done), but it violates the exemption. Ruling: v1 treats
  EVERY real user message as engine-side exempt (cheap, safe); judge
  discretion over resolved exchanges is a later, separately-tested feature.
- **F9 — Synthetic user-role records are NOT user messages** ([1508] was a
  background-job system-notice). Hiding them is fine and desirable — the
  ledger must TAG real-user vs system-notice so both the judge and the
  engine exemption can tell them apart.
