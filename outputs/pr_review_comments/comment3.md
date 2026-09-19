🟡 **IMPORTANT (standing): PTY scenario still needs the root-cause fix or a `retry:`**

Status unchanged from the previous round (no new commits to this file): the
strengthened every-response 400 ms delay improved diagnostics but did not
cure the flake — it failed 1 of 2 runs last round with the entire
first-tool-call row pair (running `•` and settled `✓`) absent from the
transcript. A row never committed to the transcript can never paint, so no
delay tuning fixes this; it points to a row-loss path in the CLI output
pipeline under compressed timing (localhost mock + instant `echo`), worth
its own issue. Until then this scenario will intermittently fail the
`--tags integration` leg — add `retry:` or soften the "success tint
painted" precondition and keep the SGR state-machine contract.
