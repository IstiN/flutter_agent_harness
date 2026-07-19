---
name: read
description: Description of the read tool — text/image reads with offset/limit, the trailing-selector grammar (:A-B, :A+C, multi-range, :raw), hashline mode, archive inner paths, and SQLite targets.
---
Read the contents of a text file or image. Text output is truncated to {{maxLines}} lines or {{maxBytesKb}}KB (whichever is hit first). Use offset/limit for large text files. Images are returned as base64 content.

## Path selectors

Append a trailing selector to `path` to read exactly the lines you need:

- `:N` — start at line N (1-indexed), through end of file. `:N-` is the same.
- `:A-B` — inclusive line range (`:A..B` works too).
- `:A+C` — C lines starting at A.
- `:R1,R2,…` — multiple ranges, sorted and merged (`:5-16,960-973`); blocks are joined with a `…` separator and ranges past end of file are reported as skipped.
- `:raw` — verbatim content: no line numbers, no hashline header, no notices. Combine as `:raw:50-100` or `:50-100:raw`.

Do not combine `offset`/`limit` with a path selector. Selectors only apply to text files (not images).

## Archives

Read inside `.zip`, `.tar`, `.tar.gz`/`.tgz` files: `archive.zip` lists the root, `archive.zip:dir/` lists a directory, `archive.zip:inner/file.txt` reads a member (selectors apply, e.g. `archive.zip:inner/file.txt:50-60`). Binary members return a note.

## SQLite databases

When the host supports it, `.db`/`.db3`/`.sqlite`/`.sqlite3` paths read as databases: `data.db` lists tables, `data.db:table` shows the schema plus sample rows, `data.db:table:key` fetches one row by primary key (or rowid), `data.db:table?limit=20&offset=40&order=col:desc&where=...` pages a table, and `data.db?q=SELECT ...` runs a raw read-only query.

## Hashline mode

Set hashline=true to prefix lines with line numbers and a [path#TAG] content-hash header for anchoring hashline edit patches (line numbers stay correct on ranged reads). Suppressed by `:raw`.
