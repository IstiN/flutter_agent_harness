# Re: 🟡 IMPORTANT (still open from round 1): flaky assertion — the painted done-row frame can be coalesced away

Fixed this round — same change as the round-1 thread on this file: the scripted mock delays 400 ms before answering requests `n >= 1` (the settled row's frame can no longer be coalesced away), and the `toolSuccessBg`/`toolErrorBg` assertions are now `waitForText` polls with a 30 s timeout instead of post-hoc `contains` on the accumulated stream. See `outputs/review_replies/thread_1.md` for the mechanism; 12+ consecutive green runs of the suite after the change.
