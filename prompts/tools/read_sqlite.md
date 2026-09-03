---
name: read_sqlite
description: SQLite subsection of the read tool description, gated on host engine availability (issue 19).
---
## SQLite databases

When the host supports it, `.db`/`.db3`/`.sqlite`/`.sqlite3` paths read as databases: `data.db` lists tables, `data.db:table` shows the schema plus sample rows, `data.db:table:key` fetches one row by primary key (or rowid), `data.db:table?limit=20&offset=40&order=col:desc&where=...` pages a table, and `data.db?q=SELECT ...` runs a raw read-only query.
