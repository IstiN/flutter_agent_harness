# verifier_integrity fixtures (gh-1579)

Two kinds of pinned inputs. Regenerate ONLY the synthesized ones.

## Synthesized (`*-test-stdout.txt`) — regenerable

Deterministic, byte-stable syntheses emitted by `generate.py`
(`python3 generate.py` from this directory): the `hoBwRwp` incident
shape and the four clean siblings, rebuilt from the evidence quoted in
the ticket. These pin the detector LOGIC.

## Real (`*-test-stdout.real.txt`) — pinned artifacts, never regenerated

Verbatim `verifier/test-stdout.txt` bytes downloaded once from the CI
artifacts of the incident run and committed byte-for-byte, so the
merge-blocking pins (REG-1/E2E-1) protect against real-world drift the
synthesis cannot see. `generate.py` never writes these files.

| file | provenance | sha256 |
|---|---|---|
| `filter-js-from-html__hoBwRwp-test-stdout.real.txt` | run `38271607849`, job `fa-2.1-docker-cpu-4`, trial `filter-js-from-html__hoBwRwp`, artifact `harbor-job-shard-4` (id 11800060324) | `ca5364125844f932dd799d538b04259f9e5c3a035a68ab9d49a475840afde26d` |
| `filter-js-from-html__4FpkEin-test-stdout.real.txt` | same run/job, trial `filter-js-from-html__4FpkEin`, artifact `harbor-job-shard-4` | `156cfb0713eae0b728e2c6c57f2dfc5e4e6d758b656cf08fda3640a23dc6091a` |

### Why the real incident bytes matter (real-world drift vs the synthesis)

The real stdout differs from the synthesis in every detail the review
flagged as a detection risk — and the gate handles all of them:

- mixed `CRLF`/bare-`CR`/`LF` line terminators (30 CRLF, 21 bare CR,
  684 LF; the bare-CR ones are apt progress lines in the verifier's
  setup prologue);
- failure lines indented with two leading spaces
  (`  Failed to load URL: HTTPConnectionPool(...): Read timed out. ...`);
- a `RUN BATCH 0 (contains 16 tests)` header — batch ids start at 0 and
  there are 29 headers totalling 445 tests, contradicting the
  `✓ ... blocked all 439 ...` success claim (the claim's 439 wins as
  `total_tests`; the header sum is deliberately not trusted);
- urllib3 retry warnings in the real
  `WARNING  urllib3.connectionpool:connectionpool.py:874 Retrying (...)`
  log format (84 of them — 56 refused + 28 resets).

Expected verdicts (pinned by `test_verifier_integrity.py::
RealIncidentArtifactTest` and `test_summary.py::
IntegrityGateTest.test_real_incident_stdout_end_to_end`):

- `hoBwRwp` → `COMPROMISED`, batches `2,5,16,20`, `skipped_tests == 66`,
  `total_tests == 439`;
- `4FpkEin` → `OK` (the real sibling carries an apt prologue, bare-CR
  progress spam and an honestly-failing pytest summary — and zero failed
  loads; the gate must stay quiet on it).
