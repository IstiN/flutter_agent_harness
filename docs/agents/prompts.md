# Prompts live outside Dart code

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Prompts live outside Dart code

- Every LLM prompt is a Markdown file under `prompts/**` (example app:
  `flutter_app/prompts/`). Never prompt string literals in `.dart` files.
- Format: YAML frontmatter (`name`, `description`) between `---` lines,
  then body; runtime placeholders are `{{name}}` tokens.
- After editing a prompt: `dart run scripts/gen_prompts.dart` rewrites
  `lib/src/prompts/prompts.g.dart` + `flutter_app/lib/prompts.g.dart`
  (generated, never edit by hand); `test/prompts/prompts_sync_test.dart`
  gates drift.
- Bundled Codex model catalog
  (`lib/src/providers/chatgpt_codex_models_data.dart`) is generated from
  `codex-rs/models-manager/models.json` via
  `dart run scripts/sync_codex_models.dart`. Re-run the script when
  codex-rs ships a new catalog so the picker / OAuth default stay current
  without a manual edit.

