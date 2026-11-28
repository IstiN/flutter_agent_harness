---
type: fix
scope: agent
issue: 2461
---

- fix(agent): gh-2461 identical-tool-call loop guard — N=5 consecutive byte-identical
  tool-call exchanges (same name + recursively sorted-key JSON args; provider call ids
  excluded) inject ONE `<system-notice>` ("stop and re-plan") as the next request's tail
  user message, and N=8 end the run with an honest `StopReason.error` naming the call,
  the streak and the opt-out, before the next provider call. Per-call-site opt-out for
  watch/polling tools (`AgentLoopConfig.identicalCallExemptTools`); user/steering
  messages and tool-free turns reset the streak; turns whose every call failed stay the
  tool-misuse breaker's jurisdiction (issue #862) and never advance the streak;
  `identicalCallNoticeThreshold: 0` disables the guard byte-identically. REG pins: the
  `finish_reason: "error"` unknown-word replay classification (the incident's
  amplifier) and the replay path's no-duplicate-pair discipline (+2 messages/turn, one
  execution per call, dead calls never execute twice), plus the gh-2423 custom-record
  projection seam (`model_request_summary`/`shell_job_registry` stay inert in both the
  classic and structured folds). Rework (gh-2465 review): the streak resets only on
  real user/steering input — gh-2423 machine context notices no longer re-arm the
  ladder; the opt-out is now a reachable yaml setting (`agent.identicalCallExemptTools`,
  a list of tool-name strings) wired through the CLI config, the strict validator and
  the host/child agent wiring; and the guard's constructor enforces the documented
  ≤ 0 disable (`noticeThreshold > 0` assert + release-side runtime mirror).
