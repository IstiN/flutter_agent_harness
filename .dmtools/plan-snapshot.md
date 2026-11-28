# gh-2472 — wire stripRecordTags into user-facing render paths

Bug: model-facing `m<N>` record tags echo into assistant replies and reach
the user in the TUI and the Flutter app; the gh-2412 sanitizer
(`stripRecordTags`, `lib/src/compaction/record_tag.dart`) had no render-path
call sites (only the persist-side echo hygiene + hand-over dedup use it).

## Tasks

- [x] T1 — Core stream filter: `RecordTagEchoStreamFilter` (push/flush) in
  `lib/src/compaction/record_tag.dart`. Line-start-only classification
  (buffers `m`+digits until decidable; tag `m\d+ +` → swallowed incl. the
  trailing spaces; any other byte → emit verbatim; `\n` re-arms).
  `flush()` emits an undecided tail verbatim (regex contract: no trailing
  space = not a tag) and resets.
  verify: `dart test test/compaction/record_tag_test.dart` — new unit tests
  green (split-delta no flicker, multi-line, tag-only-undecided flush,
  `m3u8` kept, user-style `m2 quote` documented behavior).

- [x] T2 — CLI live streaming: `lib/src/cli/approval_commands.dart`
  `_onTextDelta` feeds the delta through the filter; `_flushAssistantStreamAtEnd`
  flushes the pending tail through the same path (refactor body to
  `_emitTextDelta(String)`). Filter is per-CLI-instance (per message
  semantics preserved: reset inside flush).
  verify: failing-first CLI test (test/cli/) — a tag split across two
  deltas never reaches the captured output (`m14` then `82 При…` → output
  has `При…`, never `m14`), prefix `>_Fa ` still printed once; then green.

- [x] T3 — TUI history replay: `lib/src/cli/tui_replay.dart` — strip the
  joined assistant text in `replayLinesTui` and in `replayLines`'
  `_replayPrefixAndBody` assistant arm.
  verify: failing-first tests in test/cli/tui_replay_test.dart — replayed
  assistant `m1482 Принято…` renders `Принято…`; user `m2 quote` verbatim.

- [x] T4 — Viewer row text: `lib/src/cli/agent_cli_viewer.dart`
  `viewerRowText` assistant arm strips.
  verify: unit test next to the existing viewerRowText tests.

- [x] T5 — App live streaming: `flutter_app/lib/services/agent_service_events.dart`
  `_appendAssistantDelta` pushes deltas through a `RecordTagEchoStreamFilter`;
  `_finalizeAssistant` flushes the tail into the streamed row before the
  final text replaces it; filter resets per run/message.
  verify: failing-first test in flutter_app/test/ — streamed `m14`+`82 При…`
  shows no flicker and final content is clean.

- [x] T6 — fa_ui display projection: `packages/fa_ui/lib/src/chat/chat_message_projection.dart`
  assistant arm wraps content in `stripRecordTags` (covers history load AND
  the live tile through `fa_chat_screen._buildTextMessage`).
  verify: failing-first tests in packages/fa_ui/test/ — projection strips
  assistant, keeps user verbatim; widget test renders the projected tile
  clean.

- [x] T7 — Golden coverage: check `flutter_app/test/goldens`/`chat_golden_test.dart`
  shape; add an assistant-tile scenario for the clean-render contract if it
  fits the existing harness cheaply; else document why the widget test
  covers it.
  verify: `flutter test` (fa_ui + app affected suites) + `scripts/check_goldens.py`.

- [ ] T8 — Full gates: `dart format`, `dart analyze`, `dart test`,
  flutter suites for touched packages. Commit per task
  (`ai.teammate <agent.ai.native@gmail.com>`, subjects `fix(ui): ...`, NO
  closing keywords).

## Decisions

- Strip is UNGATED (not keyed on `recordTagsEnabled`) for assistant-role
  text only — the ticket pins "the gh-2412 regex semantics is the
  contract"; USER text is never stripped anywhere (user rows bypass all
  strip sites).
- The existing agent finalize seam (`_withoutRecordTagEcho`, MessageEnd/
  TurnEnd) stays as is — it is the persist/complete-message boundary.
  Streaming deltas need the host-side line-boundary filter; an agent-level
  delta rewrite would hold bytes past the last delta and drop them (hosts
  aggregate deltas, not end events).
- `MarkdownSurface.render` / `AnsiMarkdown.formatAll` stay untouched: their
  feeds are sanitized at ingestion (CLI buffer) or at replay build; an
  ungated strip inside the formatters would also eat user-styled lines
  routed through them.
- Session file untouched (append-only, model-facing replay byte-identical).

## Open questions

- New golden PNGs are SDK/OS-pinned (baselines valid for SDK 3.47.4,
  nightly macOS leg): a Linux-captured baseline would break the nightly.
  T7 therefore verifies the existing goldens still pass (no widget pixels
  changed) + the fa_ui widget test pins the clean-render contract.
  documented in the task.
