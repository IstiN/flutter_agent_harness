## Automated Code Review — BLOCK

**Summary**: No new rework commits since the last review (HEAD only merged `main`); the blocking state is unchanged — conflict markers/invalid JSON are still committed in `input/gh-671/ticket.json` + `ticket.md` + `input/ticket.md`, and the self-referential runner artifacts are still on the branch. The gh-671 code itself remains verified (96 unit tests re-run green at the merged HEAD; all prior code findings resolved).

**Key Issues**:
- 🚨 Conflict markers / invalid `ticket.json` at HEAD — 5th consecutive broken state; only a factory auto-save guard + final pre-merge cleanup push can end the ping-pong.
- 🟡 Runner artifacts (`pr_diff.txt`, `pr_info.md`, `pr_discussions*`) still committed.
- 🟡 PTY scenario flake: standing since last round (entire tool-0 row pair missing in failing runs — root-cause as its own issue or add `retry:`).

**Next Steps**:
1. Factory-side: auto-save refuses unmerged paths + excludes `input/`/`outputs/` job artifacts.
2. Final cleanup push immediately before merge.
3. Root-cause the dropped tool rows or mark the PTY scenario retry-able.
