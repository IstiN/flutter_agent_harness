---
name: lsp
description: Description of the lsp tool that queries a language server (the Dart analysis server by default) for diagnostics, definitions, references, and workspace-wide renames, reduced from oh-my-pi's lsp tool prompt.
---
Query a language server for diagnostics, navigation, and renames. For Dart/Flutter workspaces the Dart analysis server (`dart language-server`) starts automatically on first use; other servers can be added via `.fah/lsp.json`.

## Ops

- `diagnostics {path}` — analyzer errors/warnings for a file. Returns `OK` when clean.
- `definition {path, line, character}` — where the symbol at the position is defined.
- `references {path, line, character}` — every reference to the symbol at the position.
- `rename {path, line, character, newName}` — rename the symbol at the position workspace-wide. The server's workspace edit is applied atomically, so barrel files and imports update together; per-file edit counts are reported.

`line` and `character` are 1-indexed and default to 1.

## Rules

- Prefer this over `bash dart analyze` for a single file; diagnostics come back scoped and severity-sorted.
- Prefer `rename` over manual search-and-replace for identifiers: the analysis server finds every reference, including exports and imports.
- Positions point at the symbol's first letter. When unsure of the exact column, `read` the line first.
- Definition/references results render as `file:line:col` with the source line; follow up with `read` for more context.
- If no server is configured for a file type, add one to `.fah/lsp.json` (servers map with `command`, `args`, `fileTypes`, `rootMarkers`).
