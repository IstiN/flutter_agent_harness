# Issue #148 — Structured compaction: hide-in-place, checkpoints, compact_expand

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/148
- **PR (squash merge):** https://github.com/IstiN/flutter_agent_harness/pull/173 (`e335c933`)
- **Date:** 2026-09-12
- **Surface:** `lib/src/compaction/structured/*` (engine, judge, ledger, projection, markers, expand tool), `lib/src/session/session_record.dart`, config chain (`cli_config.dart`, `config_service.dart`, `settings_registry.dart`), `bin/fah.dart`, `flutter_app/lib/services/agent_service.dart`, prompts
- **Chain:** I148 (core) → I148b (config chain + compact_expand + CLI + prompts) → I148c (app wiring + parity + trajectory appendRecord + integration suite; 2 real bug fixes) → I148d (CRAP refactor + 2 review rounds)

## What shipped

A second compaction engine (`compaction.engine: structured` alongside `classic`)
that relieves context pressure **without rewriting history**:

1. **Judge-hide pass** — an LLM judge (smol role, prompt-cache-fed, ~$0.003/relief)
   picks ledger seqs to hide; `validateHidePicks` strips unknown/exempt ids and
   anything touching the protected last-8-entries tail; hides append
   `HiddenRangeRecord` (group-snapped outward, tool-pair integrity preserved).
2. **Checkpoint pass** — only when hiding alone cannot get under the window:
   an inward-cut-snapped range is summarized once into a `CompactCheckpointRecord`
   covering whole groups; rendering swaps the covered span for one
   `[a-b:ckpt·~Ntok]` marker.
3. **Projection/render** — `renderStructuredMessages` walks the visible branch:
   hidden records become `[seq:hidden·kind·~Ntok]` markers (≤ 12 tokens all-in),
   covered ranges collapse into their checkpoint marker, orphans downgrade to
   user-role markers (pair integrity again), customs either project or hide as
   notice markers — never silently dropped.
4. **`compact_expand` tool** — the agent claw-back path: re-materialize any
   hidden/checkpointed range by seq or pasted marker, paged (`pageChars`),
   with a per-turn token budget charged on the **delivered page** so giant
   segments stay expandable (sum over pages ≈ segment cost).
5. **Config chain** — `.fah` config → CLI flags → app settings, with classic as
   the default and structured opt-in; prompts registered; `fa-self-config`
   SKILL.md documents the `compaction:` section (pinned by a sweep test).

## Acceptance evidence (AC1–AC9)

| AC | Proof |
|----|-------|
| AC1 config chain | `memory_config_test` + `agent_cli_test` cases |
| AC2 losslessness | 30-seed property test: hide/checkpoint/render preserve every tool pair |
| AC3/AC3b marker budget | every marker ≤ 12 tok; ids ≤ 999 999 ≤ 4 tok; total ≤ 2% of a 128k window |
| AC4 addressing stability | seqs stable across reloads (`RecordSeqIndex`, 1-based incl. JSONL header) |
| AC5 two-pass relief | judge-only hides carry reliefs; instrumentation: ≥ 1 call/relief, cached share 0.950, $0.00321/relief via `calculateCost` |
| AC6 recall | IT-recall/IT-nesting through the agent loop |
| AC7 wire shape | projection/ledger unit pins |
| AC8 replay | replay through hidden/checkpointed records |
| AC9 coexistence | classic and structured engines side by side |

## Bugs found in flight (the interesting part)

1. **`SessionRecord.fromJson` regression** — the new `hidden_range` /
   `compact_checkpoint` cases *replaced* the `'label'`/`'session_info'` arms:
   session names, folder model triples and agent registries were silently lost
   on reload (8 red CLI tests). Fix: restore both arms alongside the new ones.
2. **SKILL.md drift** — `fa-self-config/SKILL.md` lacked the `compaction:`
   section; the sweep test pins the section and byte-sync with the bundled
   `flutter_app/assets/skills/...` copy.
3. **Expand budget self-denial** — charging the whole segment per expand made
   a >32k-token segment permanently unexpandable; per-page charging (S6) fixed
   it with convergence to segment cost when fully paged.

## Review rounds

- **Round 1 (CHANGES_REQUESTED):** custom records silently dropped (→ explicit
  `CustomMessageRecord` case: project or notice-marker), judge-hidden
  checkpoints swallowing ranges (→ hidden ckpt renders neither marker nor
  swallow), per-page budget (fixed above), unrelated churn (→ `memory/note`
  rewrites + plugin registrants reverted byte-identical to main, 93→46 files).
- **Red gate after main merges:** CRAP ratchet 28.18 on `_projectRecord`
  (new branches without coverage) → coverage tests + `_coverAt`/`_customAt`
  helper split → CC 10, Max CRAP 12.00.

## Gates at merge

Coverage 92.36% (baseline 80%), Max CRAP 12.00 (threshold 12), jscpd <1% lib,
`dart analyze` clean (pre-existing infos only), compaction suite 164 tests.

## Lessons

- `dart test | tail` masks the exit code (pipeline status is `tail`'s) —
  capture `DART_EXIT=$?` directly.
- One edit hunk per tool call on formatted files; re-read the region after
  every edit — line drift cost four repair rounds this issue.
- At 100% coverage CRAP = CC, so the ratchet reduces to "extract helpers until
  every function is CC ≤ 12"; coverage-first for low-CC functions.
- Reviewer churn flags are cheap to honor: `git checkout origin/main -- <paths>`
  and prove byte-identity (`git diff origin/main --name-only -- <path>` empty).
