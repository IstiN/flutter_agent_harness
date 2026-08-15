# Phase 0 — Publish `fa_llm` and `flutter_agent_memory` to pub.dev

**Status: done** (shipped on main).

Repo: `/Users/Uladzimir_Klyshevich/git/flutter_agent_memory`
Package on pub.dev: https://pub.dev/packages/flutter_agent_memory (currently
**0.0.1**, published earlier; local tree is **0.0.2**, `publish_to: none`).

## Why this phase exists

`flutter_agent_harness` auto-releases to pub.dev on every push to `main`. A
published package **cannot depend on a git or path package**, so before the
harness can take a dependency on `flutter_agent_memory`, the memory package
itself must be on pub.dev — and since it currently depends on `fa_llm` via a
**git dependency** (which pub.dev rejects in published packages), `fa_llm`
must be published first.

Current state (verified 2026-08-09):

- `flutter_agent_memory/pubspec.yaml`: `version: 0.0.2`, `publish_to: none`,
  git dep on `fa_llm` (`packages/fa_llm` in `IstiN/flutter_agent_harness`).
- `packages/fa_llm/pubspec.yaml`: `version: 0.1.0`, `publish_to: none`,
  **not on pub.dev** (API returns NoSuchKey).
- `flutter_agent_memory` has `LICENSE`, `CHANGELOG.md`, topics, homepage,
  repository — good starting point. 243 unit tests green
  (`dart test --exclude-tags integration`; `integration` = live Ollama).

## Known issues to fix in `flutter_agent_memory` before publishing

1. **Git dependency blocker** — `fa_llm` git dep makes the package
   unpublishable. Resolution: publish `fa_llm` 0.1.0 to pub.dev first, then
   switch to `fa_llm: ^0.1.0`.
2. **`print()` in library code** — `lib/src/search/kb_search_engine.dart:151`
   prints during search. Replace with an injectable `void Function(String)?
   logger` (default null = silent). Libraries must not write to stdout.
3. **O(N) full scan per search** — `KBSearchEngine` and
   `MemoryDedupService` read every record on each query. Acceptable for
   v0.1.0, but add a per-`KbStorage` in-memory tag index (rebuilt lazily,
   invalidated on writes through `KBMemoryStore`) so the CLI use case (hundreds
   of notes) stays fast. File a follow-up issue if it grows.
4. **Version/changelog** — bump to `0.1.0` (new public surface since 0.0.1:
   memory levels, provenance, revision tokens, dedup, sqlite/http/web
   storages), write the CHANGELOG section.
5. **README accuracy** — make sure the README documents the actual public
   entry points (`flutter_agent_memory.dart`, `flutter_agent_memory_web.dart`,
   `storage.dart`) and the `KbStorage` contract, since phase 1 depends on it.

## Step-by-step checklist

### 0.1 Publish `fa_llm` (in the `flutter_agent` repo)

- [x] `packages/fa_llm/pubspec.yaml`: remove `publish_to: none`; add
      `repository: https://github.com/IstiN/flutter_agent_harness`,
      `homepage`, `topics` (`llm`, `openai`, `openrouter`, `ollama`),
      verify `LICENSE` is reachable (symlink or copy the repo-root MIT
      LICENSE into `packages/fa_llm/`).
- [x] `packages/fa_llm/CHANGELOG.md`: add `## 0.1.0` entry.
- [x] `cd packages/fa_llm && dart pub publish --dry-run` — must be clean
      (no git deps inside `fa_llm` itself; its deps are `http`/`meta`, fine).
- [x] Publish: `dart pub publish` (uses the existing pub credentials of the
      maintainer; if not logged in — `dart pub login`).
- [x] Verify `https://pub.dev/api/packages/fa_llm` returns 0.1.0.

### 0.2 Fix + publish `flutter_agent_memory`

- [x] Switch dep: `fa_llm: ^0.1.0` (remove the git block), remove
      `publish_to: none`, bump `version: 0.1.0`.
- [x] Fix the `print()` in `kb_search_engine.dart` (injectable logger).
- [x] Add the lazy tag index to `KBSearchEngine` (or a scoped, tested
      minimal version of it); keep the heuristic scoring unchanged.
- [x] `CHANGELOG.md`: `## 0.1.0` — levels/provenance/revisions/dedup/new
      storages + the fixes above.
- [x] `dart test --exclude-tags integration` green; `dart analyze` clean;
      `dart format --set-exit-if-changed lib test bin` clean.
- [x] `dart pub publish --dry-run` clean; check the pana report
      (`dart pub global run pana --no-warning .` if available) — aim ≥ 130
      points, fix trivial doc issues.
- [x] `dart pub publish`.
- [x] Verify pub.dev page: version 0.1.0, platforms (the web export must keep
      it wasm/web-compatible — `dart:io` files are reachable only via
      `flutter_agent_memory.dart`, so pub's platform detection may tag it
      VM-only; acceptable for v0.1.0, note as follow-up), score, docs render.

### 0.3 Pin down the contract phase 1 will use

- [x] Document in the memory repo's README: "`KbStorage` is the integration
      seam — implement `readEntity/writeEntity/deleteEntity/listEntityIds` +
      `readFile/writeFile/listFilePaths` + `loadContext` over any backend;
      `KBMemoryStore(storage, provider:)` and `KBSearchEngine` work against
      any implementation."
- [x] Confirm the web-safe export `flutter_agent_memory_web.dart` covers
      everything phase 1 needs (models, `KBMemoryStore`, `KBSearchEngine`,
      `KbStorage`, InMemory storage). If a class is missing, move it out of
      the dart:io import graph rather than duplicating it.

## Out of scope

- Publishing the demo Flutter app (it ships separately via its own release
  workflow).
- Vector search / embeddings — deliberately not planned; retrieval stays
  tags + keywords + LLM rerank.

## Done when

`fa_llm` 0.1.0 and `flutter_agent_memory` 0.1.0 are live on pub.dev, and
`dart pub add flutter_agent_memory` in a scratch project resolves with hosted
deps only.
