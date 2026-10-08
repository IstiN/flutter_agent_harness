---
name: fa-self-improve
description: When a live session exposes an FA harness limitation or design gap (an agent failure caused by a MECHANISM — compaction burying instructions, a gate masking another, a watch tripping on stray edits), turn it into a harness-improvement goal card end-to-end — root-cause the mechanism in code, draft via the create-goal discipline THROUGH a subagent, file the issue with gh, enforce WIP status, and HARD-VERIFY the subagent's output. Use when the user says the harness itself must be fixed so a failure class can't repeat, or asks to file/verify an improvement ticket from session findings.
argument-hint: "[problem observed in session]"
---

# FA Self-Improve — session findings → harness improvement cards

This skill encodes the workflow proven on the 2026-10-08 night incident
(skills' operative lines dying in compaction folds → card #1409): a live
session is the best harness test suite there is, but only if its failures
are converted into durable, correction-proof cards instead of war stories.

The dividing line for using this skill: **the failure must belong to FA, not
to the agent's judgment.** "The model ignored an instruction" is not a
harness bug — "the instruction was physically removed from context by
compaction" is. When the mechanism, not the discipline, failed, file a card.

## Workflow (five steps, each with an exit condition)

### 1. Define the problem as a MECHANISM, not a symptom

Write one sentence of the form: *"<input state> causes <mechanism> so
<observable failure>, and <what amplified it>."* If you cannot name the
mechanism, you have a symptom — go to step 2 before writing anything.

Include the amplification path. Incidents stick through self-precedent:
hours of successful execution with the wrong behavior outweigh a lost
instruction. State plainly WHY the failure survived as long as it did
(masking, missing conflict signal, inheritance through handoff documents).

**Exit condition:** one sentence a maintainer can falsify against the code.

### 2. Root-cause in code — pinned facts only

Locate the exact subsystem and pin real facts: file paths, constants,
function names, thresholds — verified against the working tree, never from
memory of how it "probably" works. If the surface is unfamiliar, dispatch a
read-only `explore` subagent for the code search; do not burn chief context
on greps.

Every pinned fact gets the source line (e.g. `_toolResultMaxChars = 2000`
in `lib/src/compaction/compaction.dart`). Facts without sources are
assumptions and must be re-derived or cut.

**Exit condition:** each mechanism claim in the step-1 sentence maps to a
pinned code fact.

### 3. Draft THROUGH a subagent, using create-goal

Dispatch ONE `task` subagent with a self-contained brief containing:
(a) READ-FIRST order for `.fah/skills/create-goal/SKILL.md` — its discipline
governs the card text (frame sentence, tiered inventory, pinned facts with
pos/neg tests, threat model, test matrix, retracted framings);
(b) the full material: incident, mechanism chain (a)–(d) style, pinned code
facts, the proposed solution shape, and the scope decision (one focused
card; adjacent fixes → a Related Work / non-goals section, not scope creep);
(c) the filing step: `gh issue create -R <repo> --title … --body-file …`
with per-call `XDG_CACHE_HOME=$(mktemp -d)` hygiene, then verify with
`gh issue view` and report ONE line: issue number + URL.

The subagent exists so the drafting cost (reading the whole skill + repo
surface) is spent in a fresh context, not the chief's working window — the
chief keeps only the verification (step 5).

**Exit condition:** subagent reports issue number + URL.

### 4. File with the correct STATUS

Default status for a design card awaiting the owner's implementation
greenlight: **WIP**. This repo has NO `wip` label — the convention is the
title prefix `[WIP]` (see #913, #683; composed as `[WIP][GOAL] …`). Apply it
at filing time when possible, at verification time at the latest
(`gh issue edit <n> --title '[WIP][GOAL] …'`). A card is un-WIPed only by
explicit owner instruction or when implementation is dispatched.

**Exit condition:** the issue title carries the status the owner expects.

### 5. HARD-VERIFY the subagent's result (never trust "filed")

Read the filed issue BODY IN FULL. Do not sample the head and approve. Check
every discipline marker:

- one-sentence product frame present;
- incident included with the mechanism chain and amplification;
- retracted framings section (prevents owner re-litigating dropped designs);
- pinned platform facts EACH carrying positive AND negative tests;
- tiered inventory (core / second tier / excluded-with-rationale);
- security threat model naming what is attacker-controlled;
- ACs testable, test matrix layered UT/IT/E2E/REG with a merge rule;
- non-goals separating Related Work from this card's scope;
- references cite real file paths — spot-check two against the working tree;
- `gh issue view` confirms OPEN; linkage lines (`Fixes #…`) render.

Then report to the owner: issue number + URL + the verification verdict.
A card that fails the checklist is fixed by editing the issue, not by
re-filing a duplicate.

**Exit condition:** owner has number, URL, and "verified against the
checklist" — not "the subagent said it created it".

## HARD RULES

1. **The chief verifies; the subagent drafts.** Never both in one head. The
   verification step is mandatory even when the subagent's report looks
   complete — "completed" is a status, not a quality verdict.
2. **Mechanism or it didn't happen.** No card ships on a behavioral story
   alone; every causal link is a pinned code fact (step 2).
3. **One card, one mechanism class.** Adjacent fixes (detection nudges,
   spawn-time stamping, conflict surfacing) go to Related Work / non-goals —
   a card that fixes three things ships none of them.
4. **WIP by default** for design cards; `[WIP]` title prefix, not a label.
5. **The incident is test data.** Cite it in the card (what misrouted, how
   long, what propagated) — a threat model section that cannot point at a
   real failure reads as fiction.

## Worked example (the 2026-10-08 incident, compressed)

- **Mechanism sentence:** "Skill bodies enter context as read tool-results;
  compaction folds them by token position with no verbatim-preserve duty,
  so operative lines ('use fleet_sweep.sh, never hand-roll') die in the
  paraphrase — amplified by the surviving system-prompt INDEX (recognition
  without compliance) and five handoff maps re-imprinting the wrong method."
- **Pinned facts:** `formatSkillsForPrompt` index-only rendering
  (`lib/src/skills/skills.dart`); `_toolResultMaxChars = 2000` summary-input
  truncation; `findCutPoint` ~20k recent tokens; image-registry carrier
  precedent (`lib/src/agent/image_registry.dart`); resume re-injects the
  index, never bodies.
- **Subagent:** read create-goal → draft + file → #1409.
- **Verification:** full-body read against the checklist; facts spot-checked;
  WIP prefix applied after filing; reported number+URL+verdict.
- **Result:** `[WIP][GOAL] Compaction-pinned skill operative lines —
  instructions must survive folding (image-carrier precedent)` (#1409).
