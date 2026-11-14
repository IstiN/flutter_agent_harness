# Golden tests are MANDATORY for UI work

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Golden tests are MANDATORY for UI work

Any change to `flutter_app/lib/` UI code is INCOMPLETE until its golden
tests are done right:

1. **Coverage first.** New widget file → tests in
   `test/golden/<area>_golden_test.dart` + map entry in
   `golden_guard_test.dart` (hard-fails otherwise). Changed visuals →
   regenerate affected snapshots.
2. **Real fonts.** `setUpAll(ensureGoldenFonts)` in every golden file;
   placeholder-box glyphs = garbage, redo.
3. **Full frames.** Snapshots are marketing material: full app frames
   (`goldenSizeDesktop` 1280x800, `goldenSizePhone` 390x844) with realistic
   content — never a widget floating on black void.
4. **Determinism.** Fixed data/timestamps, existing-test fakes, no
   network/engines/infinite animations.
5. **Eyes on pixels.** After `--update-goldens`, OPEN every changed PNG
   (no tofu, no overflow, legible buttons/icons) before committing.
6. **Green gate.** `flutter test test/golden` passes; pre-commit runs it +
   `scripts/check_goldens.py` (which also hard-fails on ORPHAN snapshots —
   committed PNGs no test references; delete stale files, never let them
   rot in git history).

