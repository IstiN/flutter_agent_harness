# PR Discussion History

_Previous review discussions for PR #674._

## Review Threads (Inline Comments)

### Thread 1 — `test/integration/theme_readability_pty_test.dart`

**ai-teammate** (2026-09-19):
🟡 **IMPORTANT: Flaky assertion — the painted done-row frame can be coalesced away**

This assertion failed on a batch run of this exact suite on a Linux runner
(`dracula: the done row must tint with toolSuccessBg — does not contain
'48;2;40;56;46'`) and passed on re-run, i.e. it is timing-dependent.

Mechanism: with a localhost mock and instant `echo` commands, both scripted
tool calls complete within a frame interval. The tool row can then transition
running → settled without the TUI ever emitting a frame where the row wears
the `toolSuccessBg` tint (in the failed run the raw stream contained no
done-row paint at all — the final transcript only showed the failed row).
`rawOutput` is cumulative, so a frame that is never emitted can never
satisfy `contains(bg(t.toolSuccessBg))`.

Suggestions to de-flake (any one):
- add a small delay (e.g. 300–500 ms) between scripted mock responses so the
  done-row frame is guaranteed to be emitted before the next tool call starts;
- or wait for the done-row tint with `waitForText`/polling instead of
  asserting on the accumulated stream after `scenario-complete`;
- or make the "both tints really painted" precondition soft and keep only the
  SGR state-machine contract (which is vacuously true when a tint never
  appears).

As-is this will intermittently fail CI on the `--tags integration` leg.

---

### Thread 2 — `test/cli/tui_theme_test.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION: 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`**

`tuiToolRow` paints the label in `toolTitle` over BOTH tints — done rows use
`toolSuccessBg`, failed rows `toolErrorBg` — but this matrix only asserts
`toolTitle` on `toolErrorBg`. A future palette whose `toolTitle` clears 3:1 on
the error tint but not the success tint would slip through the floor
enforcement unnoticed.

Extend the pair list to cover both tints for the label (mirroring how the
glyph rails are checked per-tint):

```dart
for (final (name, tint) in [
  ('toolSuccessBg', bgOf(t.toolSuccessBg)),
  ('toolErrorBg', bgOf(t.toolErrorBg)),
]) {
  expect(
    themeColorContrast(fgOf(t.toolTitle)!, tint!),
    greaterThanOrEqualTo(kThemeSecondaryTextFloor),
    reason: '${entry.key}: toolTitle on $name',
  );
}
```

---

### Thread 3 — `lib/src/cli/fa_tui_rows.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION: truncated selected rows lose the new accent wrap (and the comment above is now stale)**

With this change, a selected plain label wears the selection accent — but only
on the non-truncated path of `_menuItemRow`. The truncated branch
(`'$prefix${_fitWidth(plain, termWidth - 2)}'`, ~line 106) still renders the
stripped label without the accent, so a long label in a generic picker
(themes/sessions/settings) reverts to the "invisible selection" behavior this
PR fixes. The comment there — "`plain` carries no `\x1b[0m`, so
`_rearmSelection` would be a no-op here" — is also stale after this change
(plain labels are exactly what now gets wrapped).

Consider applying the accent wrap after `_fitWidth` in the truncated branch
(e.g. `selected ? '$open${_fitWidth(plain, …)}\x1b[0m' : …`) and updating the
comment.

---

### Thread 4 — `lib/src/cli/tui_theme.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION: this reformat introduces a new analyzer info**

Splitting this guard onto two lines without braces trips
`curly_braces_in_flow_control_structures` — `dart analyze` on this file now
reports 3 issues vs 2 on `main` (the two pre-existing
`implementation_imports` infos). The single-line form it replaced was
lint-clean.

Either keep the one-liner or add braces:

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

---

### Thread 5 — `lib/src/cli/tui_theme.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION: `kDefaultTuiTheme`'s "byte-identical" doc promise is now stale**

The doc comment on `kDefaultTuiTheme` (line ~75) still claims *"Truecolor
output is byte-identical to the pre-theming CLI."* Adding an explicit
`toolOutput` foreground breaks that invariant on purpose — the regenerated
`tui_theme_default.ans` golden now emits `38;2;184;194;206` on every dim
detail segment. The change itself is right (it is the gh-671 fix), but the
doc should stop promising byte-identity, e.g. *"…the historical site palette;
detail text carries an explicit foreground since gh-671."*

---

### Thread 6 — `input/gh-671/ticket.json`

**ai-teammate** (2026-09-19):
🚨 **BLOCKING: unresolved git merge-conflict markers committed to the branch**

This file is committed at HEAD with TWO nested, unresolved stash-conflict
blocks (`<<<<<<< Updated upstream` / `=======` / `>>>>>>> Stashed changes`,
lines 5–13) and is **no longer valid JSON** (`json.loads` fails: "Expecting
property name enclosed in double quotes: line 5"). The same markers are
committed in `input/gh-671/ticket.md` (lines 8–19) and `input/ticket.md`
(lines 3+).

Beyond being broken content in the repo, an invalid `ticket.json` will fail
the next factory job that parses it.

Fix: resolve the conflicts (keep the version with the `## Machine jobs`
section) and re-commit — or drop these runner artifacts from the PR entirely
(see the related comment on `input/gh-671/pr_diff.txt`).

---

### Thread 7 — `input/gh-671/pr_diff.txt`

**ai-teammate** (2026-09-19):
🟡 **IMPORTANT: the PR commits the CI runner's own input artifacts — including its own diff**

`input/gh-671/pr_diff.txt` is the truncated diff OF THIS PR, committed INTO
this PR — a self-referential artifact that changes on every factory run and
grows the diff noise each time. Same for `input/gh-671/pr_info.md`. These are
job inputs generated by the automation, not source changes for gh-671.

The repo already tracks `input/` artifacts from earlier jobs (e.g.
`input/gh-623/`), so this looks like an established leak in the factory
commit step — but it should be fixed at the source: the dev job's auto-save
should `git add` only the intended paths (or `input/` should be gitignored
for job branches). At minimum, drop `pr_diff.txt`/`pr_info.md` from this PR
before merge.

---

### Thread 8 — `test/integration/theme_readability_pty_test.dart`

**ai-teammate** (2026-09-19):
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

---

### Thread 9 — `test/cli/tui_theme_test.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION (still open from the previous review round): 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`**

`tuiToolRow` paints the label in `toolTitle` over BOTH tints — done rows use
`toolSuccessBg`, failed rows `toolErrorBg` — but this matrix only asserts
`toolTitle` on `toolErrorBg`. A future palette whose `toolTitle` clears 3:1 on
the error tint but not the success tint would slip through the floor
enforcement unnoticed. Extend the pair list to cover both tints, mirroring
the per-tint glyph-rail checks below.

---

### Thread 10 — `lib/src/cli/fa_tui_rows.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION (still open from the previous review round): truncated selected rows lose the new accent wrap**

With this change a selected plain label wears the selection accent — but only
on the non-truncated path of `_menuItemRow`. The truncated branch
(`'$prefix${_fitWidth(plain, termWidth - 2)}'`, ~line 106) still renders the
stripped label without the accent, so a long label in a generic picker
reverts to the "invisible selection" behavior this PR fixes. The comment
there ("`plain` carries no `\x1b[0m`, so `_rearmSelection` would be a no-op
here") is also stale after this change. Consider applying the accent wrap
after `_fitWidth` in the truncated branch and updating the comment.

---

### Thread 11 — `lib/src/cli/tui_theme.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION (still open from the previous review round): this reformat introduces a new analyzer info**

Splitting this guard onto two lines without braces trips
`curly_braces_in_flow_control_structures` — `dart analyze` on this file
reports 3 issues vs 2 on `main` (the two pre-existing `implementation_imports`
infos). The single-line form it replaced was lint-clean. Either keep the
one-liner or add braces:

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

---

### Thread 12 — `lib/src/cli/tui_theme.dart`

**ai-teammate** (2026-09-19):
🔵 **SUGGESTION (still open from the previous review round): `kDefaultTuiTheme`'s "byte-identical" doc promise is stale**

The doc comment on `kDefaultTuiTheme` (line ~75) still claims *"Truecolor
output is byte-identical to the pre-theming CLI."* Adding an explicit
`toolOutput` foreground breaks that invariant on purpose — the regenerated
`tui_theme_default.ans` golden now emits `38;2;184;194;206` on every dim
detail segment. The change is right (it is the gh-671 fix), but the doc
should stop promising byte-identity.

---

### Thread 13

**ai-teammate** (2026-09-19):
## Automated Code Review — COMMENT

**Summary**: Solid, well-tested fix for gh-671 — explicit floor-checked foregrounds over tints, the `✓ current` picker marker, 7-theme golden coverage, and a real PTY suite. Verified locally: 95 unit tests pass, `dart format` clean. One important concern: the new PTY test flaked once in three local runs (a painted done-row frame can be coalesced away when the mock answers instantly) — worth de-flaking before it haunts CI.

**Key Issues**:
- 🟡 `theme_readability_pty_test.dart` — timing-dependent `toolSuccessBg` assertion (observed 1 failure in 2 batch runs; passes in isolation).
- 🔵 Floor matrix checks `toolTitle` only on `toolErrorBg`, not `toolSuccessBg`.
- 🔵 Truncated selected picker rows still lose the accent wrap; stale comment at `fa_tui_rows.dart:105`.
- 🔵 New `curly_braces_in_flow_control_structures` info from a reformat in `tui_theme.dart:383`; stale "byte-identical" doc on `kDefaultTuiTheme`.

**Non-inline observations** (unchanged/out-of-diff code):
- `test/cli/fa_tui_fuzzy_roles_test.dart`'s new test mutates the global `FaThemeController` (`addUserThemes('moss')` + `switchTo`) with no reset/tearDown — fine today (it's the last test in the file), but makes the file order-dependent.
- Diff noise unrelated to the ticket: 22 `memory/` notes gain `level: 2` frontmatter, `.codegraph/.gitignore` is deleted, and `input/`/`outputs/` runner artifacts are committed. Consistent with the repo's dogfooded-memory convention, but a separate `memory:` commit would keep the PR focused.

**Next Steps**:
1. De-flake the PTY done-row tint assertion (mock delay or poll for the tint).
2. Optionally extend the 3:1 label matrix to `toolSuccessBg` and fix the truncated-row selection wrap.

---

### Thread 14

**ai-teammate** (2026-09-19):
## Automated Code Review — BLOCK

**Summary**: The gh-671 code itself is unchanged since the last round (95 unit tests re-verified green after the main merge), but the new auto-save commits introduce a blocker: unresolved merge-conflict markers are committed in `input/gh-671/ticket.json` (now invalid JSON), `input/gh-671/ticket.md`, and `input/ticket.md`, and the PR now carries the CI runner's own artifacts — including a self-referential `input/gh-671/pr_diff.txt`.

**Key Issues**:
- 🚨 Committed conflict markers / invalid JSON in `input/gh-671/ticket.json` (also `ticket.md`, `input/ticket.md`).
- 🟡 Runner artifacts committed into the PR (`pr_diff.txt`, `pr_info.md`) — self-referential, grows every job run.
- 🟡 Still open from round 1: flaky PTY `toolSuccessBg` assertion (no code changes this round).
- 🔵 Still open: 4 suggestions (label floor only on `toolErrorBg`; truncated-row accent wrap; new lint info at `tui_theme.dart:383`; stale "byte-identical" doc).

**Next Steps**:
1. Resolve the committed conflict markers and re-commit (or drop the `input/` artifacts from the PR).
2. Fix the factory auto-save to not commit job-input artifacts.
3. De-flake the PTY assertion; optionally address the 4 standing suggestions.

---


## General PR Comments

**ai-teammate** (2026-09-19):

🟡 **IMPORTANT: Flaky assertion — the painted done-row frame can be coalesced away**

This assertion failed on a batch run of this exact suite on a Linux runner
(`dracula: the done row must tint with toolSuccessBg — does not contain
'48;2;40;56;46'`) and passed on re-run, i.e. it is timing-dependent.

Mechanism: with a localhost mock and instant `echo` commands, both scripted
tool calls complete within a frame interval. The tool row can then transition
running → settled without the TUI ever emitting a frame where the row wears
the `toolSuccessBg` tint (in the failed run the raw stream contained no
done-row paint at all — the final transcript only showed the failed row).
`rawOutput` is cumulative, so a frame that is never emitted can never
satisfy `contains(bg(t.toolSuccessBg))`.

Suggestions to de-flake (any one):
- add a small delay (e.g. 300–500 ms) between scripted mock responses so the
  done-row frame is guaranteed to be emitted before the next tool call starts;
- or wait for the done-row tint with `waitForText`/polling instead of
  asserting on the accumulated stream after `scenario-complete`;
- or make the "both tints really painted" precondition soft and keep only the
  SGR state-machine contract (which is vacuously true when a tint never
  appears).

As-is this will intermittently fail CI on the `--tags integration` leg.

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION: 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`**

`tuiToolRow` paints the label in `toolTitle` over BOTH tints — done rows use
`toolSuccessBg`, failed rows `toolErrorBg` — but this matrix only asserts
`toolTitle` on `toolErrorBg`. A future palette whose `toolTitle` clears 3:1 on
the error tint but not the success tint would slip through the floor
enforcement unnoticed.

Extend the pair list to cover both tints for the label (mirroring how the
glyph rails are checked per-tint):

```dart
for (final (name, tint) in [
  ('toolSuccessBg', bgOf(t.toolSuccessBg)),
  ('toolErrorBg', bgOf(t.toolErrorBg)),
]) {
  expect(
    themeColorContrast(fgOf(t.toolTitle)!, tint!),
    greaterThanOrEqualTo(kThemeSecondaryTextFloor),
    reason: '${entry.key}: toolTitle on $name',
  );
}
```

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION: truncated selected rows lose the new accent wrap (and the comment above is now stale)**

With this change, a selected plain label wears the selection accent — but only
on the non-truncated path of `_menuItemRow`. The truncated branch
(`'$prefix${_fitWidth(plain, termWidth - 2)}'`, ~line 106) still renders the
stripped label without the accent, so a long label in a generic picker
(themes/sessions/settings) reverts to the "invisible selection" behavior this
PR fixes. The comment there — "`plain` carries no `\x1b[0m`, so
`_rearmSelection` would be a no-op here" — is also stale after this change
(plain labels are exactly what now gets wrapped).

Consider applying the accent wrap after `_fitWidth` in the truncated branch
(e.g. `selected ? '$open${_fitWidth(plain, …)}\x1b[0m' : …`) and updating the
comment.

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION: this reformat introduces a new analyzer info**

Splitting this guard onto two lines without braces trips
`curly_braces_in_flow_control_structures` — `dart analyze` on this file now
reports 3 issues vs 2 on `main` (the two pre-existing
`implementation_imports` infos). The single-line form it replaced was
lint-clean.

Either keep the one-liner or add braces:

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION: `kDefaultTuiTheme`'s "byte-identical" doc promise is now stale**

The doc comment on `kDefaultTuiTheme` (line ~75) still claims *"Truecolor
output is byte-identical to the pre-theming CLI."* Adding an explicit
`toolOutput` foreground breaks that invariant on purpose — the regenerated
`tui_theme_default.ans` golden now emits `38;2;184;194;206` on every dim
detail segment. The change itself is right (it is the gh-671 fix), but the
doc should stop promising byte-identity, e.g. *"…the historical site palette;
detail text carries an explicit foreground since gh-671."*

---

**ai-teammate** (2026-09-19):

🚨 **BLOCKING: unresolved git merge-conflict markers committed to the branch**

This file is committed at HEAD with TWO nested, unresolved stash-conflict
blocks (`<<<<<<< Updated upstream` / `=======` / `>>>>>>> Stashed changes`,
lines 5–13) and is **no longer valid JSON** (`json.loads` fails: "Expecting
property name enclosed in double quotes: line 5"). The same markers are
committed in `input/gh-671/ticket.md` (lines 8–19) and `input/ticket.md`
(lines 3+).

Beyond being broken content in the repo, an invalid `ticket.json` will fail
the next factory job that parses it.

Fix: resolve the conflicts (keep the version with the `## Machine jobs`
section) and re-commit — or drop these runner artifacts from the PR entirely
(see the related comment on `input/gh-671/pr_diff.txt`).

---

**ai-teammate** (2026-09-19):

🟡 **IMPORTANT: the PR commits the CI runner's own input artifacts — including its own diff**

`input/gh-671/pr_diff.txt` is the truncated diff OF THIS PR, committed INTO
this PR — a self-referential artifact that changes on every factory run and
grows the diff noise each time. Same for `input/gh-671/pr_info.md`. These are
job inputs generated by the automation, not source changes for gh-671.

The repo already tracks `input/` artifacts from earlier jobs (e.g.
`input/gh-623/`), so this looks like an established leak in the factory
commit step — but it should be fixed at the source: the dev job's auto-save
should `git add` only the intended paths (or `input/` should be gitignored
for job branches). At minimum, drop `pr_diff.txt`/`pr_info.md` from this PR
before merge.

---

**ai-teammate** (2026-09-19):

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

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION (still open from the previous review round): 3:1 label floor is only checked on `toolErrorBg`, not `toolSuccessBg`**

`tuiToolRow` paints the label in `toolTitle` over BOTH tints — done rows use
`toolSuccessBg`, failed rows `toolErrorBg` — but this matrix only asserts
`toolTitle` on `toolErrorBg`. A future palette whose `toolTitle` clears 3:1 on
the error tint but not the success tint would slip through the floor
enforcement unnoticed. Extend the pair list to cover both tints, mirroring
the per-tint glyph-rail checks below.

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION (still open from the previous review round): truncated selected rows lose the new accent wrap**

With this change a selected plain label wears the selection accent — but only
on the non-truncated path of `_menuItemRow`. The truncated branch
(`'$prefix${_fitWidth(plain, termWidth - 2)}'`, ~line 106) still renders the
stripped label without the accent, so a long label in a generic picker
reverts to the "invisible selection" behavior this PR fixes. The comment
there ("`plain` carries no `\x1b[0m`, so `_rearmSelection` would be a no-op
here") is also stale after this change. Consider applying the accent wrap
after `_fitWidth` in the truncated branch and updating the comment.

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION (still open from the previous review round): this reformat introduces a new analyzer info**

Splitting this guard onto two lines without braces trips
`curly_braces_in_flow_control_structures` — `dart analyze` on this file
reports 3 issues vs 2 on `main` (the two pre-existing `implementation_imports`
infos). The single-line form it replaced was lint-clean. Either keep the
one-liner or add braces:

```dart
if (homeDir == null || homeDir.isEmpty) {
  return (themes: themes, errors: errors);
}
```

---

**ai-teammate** (2026-09-19):

🔵 **SUGGESTION (still open from the previous review round): `kDefaultTuiTheme`'s "byte-identical" doc promise is stale**

The doc comment on `kDefaultTuiTheme` (line ~75) still claims *"Truecolor
output is byte-identical to the pre-theming CLI."* Adding an explicit
`toolOutput` foreground breaks that invariant on purpose — the regenerated
`tui_theme_default.ans` golden now emits `38;2;184;194;206` on every dim
detail segment. The change is right (it is the gh-671 fix), but the doc
should stop promising byte-identity.

---

**ai-teammate** (2026-09-19):

## Automated Code Review — COMMENT

**Summary**: Solid, well-tested fix for gh-671 — explicit floor-checked foregrounds over tints, the `✓ current` picker marker, 7-theme golden coverage, and a real PTY suite. Verified locally: 95 unit tests pass, `dart format` clean. One important concern: the new PTY test flaked once in three local runs (a painted done-row frame can be coalesced away when the mock answers instantly) — worth de-flaking before it haunts CI.

**Key Issues**:
- 🟡 `theme_readability_pty_test.dart` — timing-dependent `toolSuccessBg` assertion (observed 1 failure in 2 batch runs; passes in isolation).
- 🔵 Floor matrix checks `toolTitle` only on `toolErrorBg`, not `toolSuccessBg`.
- 🔵 Truncated selected picker rows still lose the accent wrap; stale comment at `fa_tui_rows.dart:105`.
- 🔵 New `curly_braces_in_flow_control_structures` info from a reformat in `tui_theme.dart:383`; stale "byte-identical" doc on `kDefaultTuiTheme`.

**Non-inline observations** (unchanged/out-of-diff code):
- `test/cli/fa_tui_fuzzy_roles_test.dart`'s new test mutates the global `FaThemeController` (`addUserThemes('moss')` + `switchTo`) with no reset/tearDown — fine today (it's the last test in the file), but makes the file order-dependent.
- Diff noise unrelated to the ticket: 22 `memory/` notes gain `level: 2` frontmatter, `.codegraph/.gitignore` is deleted, and `input/`/`outputs/` runner artifacts are committed. Consistent with the repo's dogfooded-memory convention, but a separate `memory:` commit would keep the PR focused.

**Next Steps**:
1. De-flake the PTY done-row tint assertion (mock delay or poll for the tint).
2. Optionally extend the 3:1 label matrix to `toolSuccessBg` and fix the truncated-row selection wrap.

---

**ai-teammate** (2026-09-19):

## Automated Code Review — BLOCK

**Summary**: The gh-671 code itself is unchanged since the last round (95 unit tests re-verified green after the main merge), but the new auto-save commits introduce a blocker: unresolved merge-conflict markers are committed in `input/gh-671/ticket.json` (now invalid JSON), `input/gh-671/ticket.md`, and `input/ticket.md`, and the PR now carries the CI runner's own artifacts — including a self-referential `input/gh-671/pr_diff.txt`.

**Key Issues**:
- 🚨 Committed conflict markers / invalid JSON in `input/gh-671/ticket.json` (also `ticket.md`, `input/ticket.md`).
- 🟡 Runner artifacts committed into the PR (`pr_diff.txt`, `pr_info.md`) — self-referential, grows every job run.
- 🟡 Still open from round 1: flaky PTY `toolSuccessBg` assertion (no code changes this round).
- 🔵 Still open: 4 suggestions (label floor only on `toolErrorBg`; truncated-row accent wrap; new lint info at `tui_theme.dart:383`; stale "byte-identical" doc).

**Next Steps**:
1. Resolve the committed conflict markers and re-commit (or drop the `input/` artifacts from the PR).
2. Fix the factory auto-save to not commit job-input artifacts.
3. De-flake the PTY assertion; optionally address the 4 standing suggestions.

---

