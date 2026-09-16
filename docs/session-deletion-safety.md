# Session deletion safety (issue #522)

A live 424 MB session file once vanished between two process launches
(support incident, 2026-09-16, 20:56–21:09 window) — no trash entry, no
journal, no trace of who unlinked it. This page documents the machinery
that makes a silent loss of a session file impossible from inside the
harness, and the forensic audit of the incident itself.

## The three invariants

1. **Deletion journal.** Every delete/move/purge of a session file lands
   as one JSONL record in `<sessionsRoot>/session_ops.journal` (always
   on, best-effort — a broken journal never blocks the operation):

   ```json
   {"ts":"2026-09-16T21:09:03.221Z","op":"trash",
    "path":"~/.fah/sessions/--proj--/2026…_01a060f2….jsonl",
    "to":"~/.fah/sessions/.trash/20260916T210903221_2026…_01a060f2….jsonl",
    "bytes":424000000,
    "actor":{"pid":85634,"host":"cli","session":"01a0…","tool":"sessions_ui"}}
   ```

   Ops: `trash` (delete), `cleanup_trash` (legacy empty-session
   cleanup), `purge` (TTL purge), `refused_live` (a live registration
   refused the operation — the audit trail for "who tried").

2. **Live-session guard.** `JsonlSessionRepo.delete` /
   `cleanupEmptySessions` consult a `SessionDeletionGuard` before
   touching the file. The default `PresenceLeaseSessionGuard` combines
   the two registration sources:
   - **presence** — the `.presence/<sessionId>.json` heartbeats a
     running `fa` CLI publishes (~4s touch, 15s staleness);
   - **lease** — the `_owner.json` ownership sidecar (#428).

   A fresh registration throws `SessionException` with
   `SessionErrorCode.sessionLive` (named refusal). Staleness is judged
   ONLY by heartbeat expiry — a crashed owner stops blocking after the
   window. The actor process itself is exempt (same pid): closing your
   own session is a graceful exit, not a fight.

3. **Trash, never unlink.** Deletion moves the file to
   `<root>/.trash/<timestamp>_<name>` (atomic rename; byte-copy
   fallback on backends without rename — the copy exists BEFORE the
   original is vacated). Trashed sessions never reappear in `list()`
   (the session walks skip dot-directories). The only unlink anywhere
   in the session layer is `purgeExpiredTrash(ttl: 30 days)` — the app
   runs it once per boot; every unlink site in `lib/src/session/` must
   carry an `// unlink-ok: <why>` marker (enforced by
   `test/session/no_session_unlink_test.dart`).

## Where it is wired

| Host | guard | journal actor |
| --- | --- | --- |
| `fa` CLI | presence store + lease store | `pid`, host `cli`, current session id |
| Flutter app (manager + service) | presence store + lease store | host `app` |
| Core `JsonlSessionRepo` default | none (journal + trash still on) | none |

## Incident forensics (2026-09-16, 20:56–21:09)

Window: a relaunched `fa --session support` resumed the 424 MB file
`2026-09-02…_01a060f2….jsonl` at ~20:56 (windowed resume, 1463/2149
messages) and was killed ~21:05; by 21:09 a new run created a fresh
header-only session — the old file was already gone, and `--session
support` no longer resolved.

Every unlink path reachable in that window, audited on the code as of
the incident:

| Path | Could it delete a 424 MB NON-empty file? |
| --- | --- |
| CLI `deleteSessionIfEmpty` (`agent_cli.dart` / `session_commands.dart`) | **No** — gated on `_agent.state.messages.isEmpty && _persistedCount == 0`; the resumed session had 1463 messages restored and a non-zero persisted count. |
| App `AgentService.deleteSessionIfEmpty` (`reset()` path) | **No** — gated on `messages.isEmpty` and `_session` pointing at the file; a load of the support session only sets `_session` after a successful open, and then messages are non-empty. |
| `JsonlSessionRepo.cleanupEmptySessions` (app boot) | **No** — decides emptiness from the first two lines; a 424 MB transcript has a second line, and a failed read throws (caught) instead of deleting. |
| App sidebar / sessions-sheet delete (`FlutterSessionManager.deleteSession`) | **Yes** — an explicit user action; silent at the time (no journal, hard unlink). |
| CLI `/sessions` picker | **No delete action existed.** |
| Open-time quarantine rewrite (`session_storage.dart`) | **Not a delete** — `writeFile` truncates+writes; a kill mid-rewrite leaves a partial file, never a missing one. |
| Browser-ext storage migration (#240) | **No** — chrome.storage surface, different machine. |
| `ext_engine_process` temp dir, config tmp rename, lease/presence sidecars | **No** — never touch session JSONL. |

Conviction: no *automated* in-repo path could unlink that file; the
code paths that could are (1) an explicit delete action from an app
surface and (2) an external `rm` — e.g. through the agent's own `bash`
tool or the OS — both of which were perfectly silent pre-#522 (the bash
transcript that would prove (2) lived inside the very file that
disappeared). The journal closes both holes: after this change every
in-repo delete names its actor in `session_ops.journal`, lands in
`.trash/` instead of vanishing, and is refused outright while any
process holds a live registration on the session.
