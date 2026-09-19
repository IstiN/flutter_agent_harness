🟡 **IMPORTANT: reproduced again this round — 3rd observed failure, always the first scenario, always the missing success row**

This run: `TimeoutException after 0:00:30 waiting for "48;2;40;56;46"`
(dracula). The failure dump again shows the ENTIRE first-tool-call row pair
missing from the transcript — no running `• bash · echo THEME-SCENARIO-OK`
and no settled `✓` row — while tool 1's rows render fine. Failure record
across rounds: round 1 (1/3 runs), round 4 (1/2), round 6 (1/1) — always
dracula, i.e. always the FIRST test in the file, which points at a
cold-start interaction rather than pure paint timing.

Two concrete next steps (beyond the previously suggested `retry:`):

1. **Localize the drop first**: assert `mock.bodies.length == 3` (or at
   least that request 1 carried the tool-0 result) before the tint waits,
   and/or read the session JSONL — this distinguishes "the CLI never
   executed/reported tool 0" from "the row was written but lost in the TUI
   output pipeline".
2. **Absorb the cold start**: run a throwaway warm-up scenario (or make the
   bare-`/theme` picker test first) so the strict tint assertions never
   run on the first CLI spawn of the process.
