---
type: feat
scope: compaction
issue: 2492
---

- feat(compaction): the hidden-ledger budget + consolidated hide labels
  (gh-2492 C4/C5) — every bare hide writer (judge hide, deterministic
  fallback, LRU re-hide, emergency relief) consolidates its batch into ONE
  `hidden_range` record with an engine-generated histogram label (tool events
  + time span over the covered records, no model text), rendered as
  `<label> [expand a-b]` at the carrier. A render-time budget
  (`hiddenLedgerBudgetTokens` = 1000 over all hidden markers of a request)
  collapses the oldest adjacent markers into working
  `N records hidden · <label> [expand a-b]` pointers until the ledger fits —
  the newest run keeps its per-record detail, the expandable set never
  changes, and a rebuild derives the identical view from the file (no
  rewrite). The engine-marker predicate's label budget grows to the engine's
  own shapes (96 chars / 16 words); model-written labels stay at the tight
  sanitizer budget.
