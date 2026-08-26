# fa CLI — TUI render/input performance

Status: **in progress** on branch `perf/tui-stream-render`.
Canonical perf log for the fa interactive TUI (`lib/src/cli/fa_tui.dart`,
`lib/src/cli/ansi_markdown.dart`), modeled on yoxterm's
[PERFORMANCE.md](../../../../yoloit/yoloit/packages/xterm/docs/PERFORMANCE.md)
and its distilled rules
([PERFORMANCE_BEST_PRACTICES.md](../../../../yoloit/yoloit/packages/xterm/docs/PERFORMANCE_BEST_PRACTICES.md)).

## Goal

Streaming a long answer must never make typing feel dead. Concretely:

- While output streams at the coalesced rate (~20 flushes/s), a keystroke
  must reach the screen within a frame (< ~16 ms of competing work) — not
  behind multi-ms markdown re-parses of the whole history.
- Visual output must stay byte-identical: the integration terminal
  snapshots and `tui_prototype_snapshot_test` are the regression gate.

## The measured baseline (this machine, AOT `dart run`, 2026-08)

Simulation of one coalesced flush over a full history
(`tool/tui_stream_bench.dart --lines 2000 --iters 25`, mixed-content
2000-line transcript — headers/bullets/inline code/links/fenced code/CJK+
emoji/table), i.e. what `_wrappedLines()` pays on EVERY flush because the
markdown pass has no memory between calls:

| Hot path | cost |
|---|---|
| `AnsiMarkdown.formatAll(2000 lines)` + wrap of all rows | **26.96 ms/pass** |
| Share of each 50 ms streaming-flush interval | **53.9%** |
| Full-history passes per streamed answer (≈20/s × minutes) | thousands |

Root cause mapping to the yoxterm rules we violated:

1. **§4 persistent parser state across chunks** — `AnsiMarkdown` is a
   per-call object: `_inFence` + the pending-table buffer die at the end
   of every `formatAll`, so nothing can ever be resumed; the whole
   transcript is re-parsed from line 0 twenty times a second.
2. **§2 damage tracking / version boundaries** — `_WrapCache` memoizes on
   list identity only: an append invalidates ALL rows, even though the
   first 1995 lines did not change. Re-wrapped them all anyway.

(Already shipped earlier and kept: §5 producer throttling — the 50 ms
`sendOutput` coalescing timer.)

## The fix: prefix-committed incremental formatting

A `TranscriptMarkdown` session owned by `_WrapCache`:

- Commits formatted results through an index `_through`, carrying the
  cross-line state (`_inFence`) across calls — the persistent-parser
  rule. Subsequent appends format ONLY the appended suffix.
- A resume boundary is valid only when the pending-table buffer is empty
  AND the raw first line is unchanged (the trim path drops lines from the
  FRONT, which flips the sentinel cheaply). Any violation → today's full
  rebuild path; correctness never depends on the guess.
- Wrap results are cached per committed source line as well (`rows`,
  `lineStartRows` extended in place); unchanged prefixes are neither
  re-formatted nor re-wrapped nor re-indexed.
- Width change or a shorter source ⇒ documented full-rebuild fallback =
  current behavior.

## Contract tests (work counters, not timings — CI-safe)

`test/cli/transcript_markdown_perf_test.dart` asserts, via debug counters
on `TranscriptMarkdown`:

1. Parity: incremental sync steps ≡ one-shot `formatAll` for adversarial
   transcripts (fence spanning a resume boundary, table at the boundary,
   table spanning many syncs, pre-styled echo lines, CJK/emoji, resize
   rebuild, front-trim rebuild).
2. Work counters: N append-syncs after the initial load format only the
   appended lines (sum of formatted lines ≈ total added + boundary look
   ahead), full rebuilds == expected triggers.
3. The model layer keeps its O(delta) property under the exact mutation
   pattern the controller produces during streaming.

## Results

Same machine, AOT `dart run`, simulation of one coalesced flush over the
2000-line mixed transcript (`tool/tui_stream_bench.dart` before,
`tool/tx_after_bench.dart` after):

| path | before | after | delta |
|---|---|---|---|
| streaming flush (grow pass, +1 burst) | **26 960 µs** | **37 µs** | **×729** |
| share of each 50 ms flush interval | 53.9 % | **0.07 %** | input no longer queues behind renders |
| keystroke-race sync (cache hit) | n/a (full pass) | **< 1 µs** | O(1) |

Contract gates shipped with it:

- `test/cli/transcript_markdown_perf_test.dart` — parity fixtures
  (fences/tables/pre-styled/CJK+emoji spanning boundaries), byte-exact
  outputs on BOTH resume and documented rebuild paths, work counters
  (`debugLinesFormatted` == delta lines appended, `debugFullRebuilds`
  counts only width changes / head-trims / tail replacements).
- Visual regression: `fa_tui_test`, `tui_prototype_snapshot_test`,
  `ansi_markdown_test` (+110 checks) green unchanged; PTY integration
  snapshots unaffected (formatter is below their layer).

Known boundary (documented, safe): after a front-trim (history cap) or a
tail-regenerating caller the next sync takes ONE legacy full pass —
byte-exact, then resumes incrementally.

## Change log

- branch opened with baseline bench + this doc (no behavior change yet).
