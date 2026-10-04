# Live LLM testing: the deterministic gate and the supervised benches

gh-1199 — the merge-blocking Quality gate answers exactly one question:
**did this PR break the code?** It runs exclusively on mock LLMs
(`MockLlmServer` and friends), so a model's mood, drift, or rate limit can
never red a merge. Real-model verification answers a different question —
**does the agent work against real models today?** — and it lives in the
bench harnesses (terminal-bench / harbor / MLS-Bench) run **under
supervision**, never in the PR path.

## The `llm` tag boundary

A test that performs live provider I/O carries `@Tags(['integration',
'llm'])`. Everything integration-tagged without `llm` is mock by
construction and runs in the deterministic gate.

| Where | Live (`llm`) tests | Mock (gate) tests |
| --- | --- | --- |
| per-PR integration shards (`pty-integration-linux`) | excluded — `shard_files.py --exclude-tag llm` at selection, `--exclude-tags browser-ext,llm` at invocation | run |
| `integration-mock` leg (no-key) | excluded (`--exclude-tags llm,...`) | run |
| tag-only provider-smoke job (`v*` tags) | run, with secrets | — |
| `nightly.yml` | run, with secrets (supervised, unsharded) | run |
| bench harnesses (terminal-bench / harbor / MLS) | run under supervision | — |
| your machine (debugging) | `dart test --tags "integration && llm"` | `dart test --tags integration --exclude-tags llm` |

The boundary is enforced, not aspirational:

- `scripts/check_llm_tag_boundary.py` (static-gate step on every PR, plus
  `test/scripts/llm_tag_boundary_test.dart` in the regular suite) fails
  when an integration-tagged file looks live — a real provider URL, or a
  credential-key literal with no mock/loopback marker — without the `llm`
  tag. A PR that legitimately adds a live test is blocked until tagged;
  genuinely deterministic files that trip the heuristic are pinned in the
  script's `AUDIT_MOCK` audit list with a justification (reviewed in the
  PR). New live tests can never silently join the gate again.
- `test/scripts/shard_files_llm_boundary_test.dart` is the AC1 red/green
  proof: it runs the exact CI shard-selection invocation and asserts no
  live file is emitted — and that without `--exclude-tag llm` one would
  be.
- `llm`-tagged files stay in the `dart analyze` scope of every PR (they
  are excluded from RUN, never from compile — no dead-code rot), and
  nightly compiles and runs them with secrets.

## Mock-script hygiene (gh-1171)

Scripted mocks serve a fixed queue; incidental LLM traffic (memory
auto-tagging, title/summary calls) used to exhaust it and 500-storm the
test. The contract since gh-1171:

- content-route the scripted conversation on unique markers — background
  noise can then never pop a scripted response;
- pin known noise to a **sticky wildcard** scenario (`sticky: true` +
  `match: "Existing tags:"`) so an extra call re-serves the last response
  forever instead of exhausting into a 500;
- keep the conversation scenarios strict — a matched-but-dry scenario must
  still fail loudly, or a real loop regression goes unnoticed.
  `test/integration/memory_taggen_script_pin_test.dart` REG-pins the
  memory leg's wildcard.

## Flake quarantine (gh-1199 AC6)

A test red in **≥2 distinct-SHA gate runs within 24h** is a proven flake
(the #1171 signature — one SHA flipping green/red is noise, one red run is
a regression). `.github/workflows/flake-watch.yml` (hourly,
`scripts/flake_watch.py`) then:

1. creates/updates a `flake`-labelled issue carrying the failing run links
   and SHAs (E3: the quarantine never swallows a real regression — the
   evidence is attached), and
2. opens a reviewable PR adding the file to
   `scripts/test_quarantine.json`.

The gate legs pipe their targets through `scripts/apply_quarantine.py`, so
a quarantined file leaves the deterministic gate until its fix PR lands.
Granularity is the file (dart test cannot exclude one test inside a file);
the entry's `test` field records the offending test. **Nightly
deliberately does NOT apply the quarantine** — the file keeps running
supervised, producing the 10/10-style repeat-run proof (gh-1199 AC4) the
un-quarantine PR must cite.

## What is NOT here

No live runs in any scheduled PR-path job; no bench-harness changes (they
already run supervised); no reduction in mock coverage — the mock suites
keep every assertion the live ones make, minus the network.
