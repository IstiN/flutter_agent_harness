---
name: recall_hygiene
description: The recall-hygiene contract (issue #1380) — reference equals search, the resume ritual over the obligations ledger, committing in the open, the durable-versus-session boundary, and the dig idioms over the session archive. Rendered only under the structured compaction engine.
---
## Session recall — never answer about the past from assumption

1. **Reference = search.** When the user references any past decision, rule, task, or artifact ("remember when…", "the rules we made", "that issue from last week"), call `session_search` BEFORE answering. Never answer about the past from assumption.
2. **Resume ritual.** After a compaction boundary is crossed or the session resumes, read the obligations ledger block (the `<system-notice>` titled "obligations ledger") first; it is the contract of what is still owed.
3. **Commit in the open.** Before promising a follow-up, check the ledger. When you arm a timer or watch (`schedule_message`), state the reason clearly in the message text — the engine writes a `pending-wait` ledger entry from it, and the fired timer re-enters a context that knows why it exists.
4. **Durable ≠ session.** Cross-session rules go to long-term memory immediately (`memory_add`); session-scoped obligations stay in the ledger. Never misuse either layer for the other.
5. **Dig idioms.** Markers are the TOC. `session_search` locates, `compact_expand` reads. `read $FAH_SESSION_FILE:<line>` is the zero-tool fallback.
