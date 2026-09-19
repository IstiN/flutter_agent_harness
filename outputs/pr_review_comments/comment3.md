🟡 **IMPORTANT (still open from the previous review round): flaky assertion — the painted done-row frame can be coalesced away**

Raised in the previous review; the file is unchanged this round, so the
finding stands verbatim:

This assertion failed on a batch run of this exact suite on a Linux runner
(`dracula: the done row must tint with toolSuccessBg — does not contain
'48;2;40;56;46'`) and passed on re-run, i.e. it is timing-dependent.

Mechanism: with a localhost mock and instant `echo` commands, both scripted
tool calls complete within a frame interval. The tool row can then transition
running → settled without the TUI ever emitting a frame where the row wears
the `toolSuccessBg` tint. `rawOutput` is cumulative, so a frame that is never
emitted can never satisfy `contains(bg(t.toolSuccessBg))`.

Suggestions to de-flake (any one):
- add a small delay (e.g. 300–500 ms) between scripted mock responses so the
  done-row frame is guaranteed to be emitted before the next tool call starts;
- or poll for the done-row tint instead of asserting on the accumulated
  stream after `scenario-complete`;
- or make the "both tints really painted" precondition soft and keep only the
  SGR state-machine contract (vacuously true when a tint never appears).

As-is this will intermittently fail CI on the `--tags integration` leg.
