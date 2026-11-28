# Changelog

<!-- GENERATED FILE — `dart scripts/gen_changelog.dart --write-changelog`.
     DO NOT HAND-EDIT: the CI changelog guard rejects direct edits
     (gh-2463). Regenerate instead. -->

Per-change entries live in `changelog/entries/` — one Markdown file per
change (`<issue-or-pr>-<slug>.md`, YAML frontmatter `type`/`scope`/`issue`
plus 1–3 user-facing bullet lines). Every PR adds ITS OWN entry file
instead of editing this file, so parallel changes never touch a shared
file (zero merge conflicts by construction). At release time the pending
entries aggregate into the `Unreleased` section below and
`scripts/release_notes.sh` folds them into the release notes; versioned
history lives in `changelog/archive/` (one file per version — the
pre-1.0.506 tail stays in `CHANGELOG_ARCHIVE.md`). Conventions:
`docs/agents/commits-releases.md`.

## Unreleased

- fix(browser_ext): provider.save drops contextWindow/custom headers (gh-2425) —
  the panel save overwrote `faProvider` with baseUrl/apiKey/model only, so every
  save reset the stored window override (gh-2059) and a 264k-token model ran on
  the shared fallback window until "Context window exhausted". `provider.save`
  now merges field-wise (the same contract as the Dart settings_put merge:
  non-empty wins, blank keeps stored, positive ints by presence,
  string-tolerant, custom headers replace-by-presence so a header line the
  user deleted actually deletes — a dropped authorization header stops riding
  requests).
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
- ci(release): the single shared CHANGELOG.md becomes per-change entry
  files — every PR adds its own `changelog/entries/<issue-or-pr>-<slug>.md`
  (zero merge conflicts by construction), `scripts/gen_changelog.dart`
  aggregates them into the release notes at cut time, and CHANGELOG.md is
  now a generated index (hand edits rejected by the CI changelog guard).
  Versioned history moved to `changelog/archive/`.
- fix(fabric): queued hub mail no longer strands off an unsettled roster (gh-2471) —
  `FallbackMessagingRepository` untracked queued mail on the first connected
  roster snapshot lacking the recipient, and after a hub restart peers re-hello
  on their own reconnect backoff, so that snapshot is not ownership evidence
  (v1.0.794 hostile-env red, run 46147543769: "queued mail not forwarded within
  20s of inbox probes"; production shape: DMs queued during a hub restart are
  silently lost). The flush now untracks on a confirmed miss only when the
  routing primary's roster is settled — the new `RosterSettleness` capability
  (`hubRosterWarmup`, 5s, rides out the first three reconnect-backoff steps);
  `HubFabricRepository` (bin/) and `HubMessagingRepository` (flutter_app
  network-join path) report settledness off their own re-welcome witness.
  Non-advertising primaries keep today's behavior.

## Archive index

- [1.0.551.md](changelog/archive/1.0.551.md)
- [1.0.550.md](changelog/archive/1.0.550.md)
- [1.0.549.md](changelog/archive/1.0.549.md)
- [1.0.548.md](changelog/archive/1.0.548.md)
- [1.0.547.md](changelog/archive/1.0.547.md)
- [1.0.546.md](changelog/archive/1.0.546.md)
- [1.0.545.md](changelog/archive/1.0.545.md)
- [1.0.543.md](changelog/archive/1.0.543.md)
- [1.0.542.md](changelog/archive/1.0.542.md)
- [1.0.541.md](changelog/archive/1.0.541.md)
- [1.0.540.md](changelog/archive/1.0.540.md)
- [1.0.539.md](changelog/archive/1.0.539.md)
- [1.0.538.md](changelog/archive/1.0.538.md)
- [1.0.537.md](changelog/archive/1.0.537.md)
- [1.0.535.md](changelog/archive/1.0.535.md)
- [1.0.534.md](changelog/archive/1.0.534.md)
- [1.0.533.md](changelog/archive/1.0.533.md)
- [1.0.532.md](changelog/archive/1.0.532.md)
- [1.0.531.md](changelog/archive/1.0.531.md)
- [1.0.529.md](changelog/archive/1.0.529.md)
- [1.0.528.md](changelog/archive/1.0.528.md)
- [1.0.527.md](changelog/archive/1.0.527.md)
- [1.0.526.md](changelog/archive/1.0.526.md)
- [1.0.525.md](changelog/archive/1.0.525.md)
- [1.0.524.md](changelog/archive/1.0.524.md)
- [1.0.523.md](changelog/archive/1.0.523.md)
- [1.0.522.md](changelog/archive/1.0.522.md)
- [1.0.521.md](changelog/archive/1.0.521.md)
- [1.0.520.md](changelog/archive/1.0.520.md)
- [1.0.518.md](changelog/archive/1.0.518.md)
- [1.0.517.md](changelog/archive/1.0.517.md)
- [1.0.516.md](changelog/archive/1.0.516.md)
- [1.0.515.md](changelog/archive/1.0.515.md)
- [1.0.514.md](changelog/archive/1.0.514.md)
- [1.0.513.md](changelog/archive/1.0.513.md)
- [1.0.511.md](changelog/archive/1.0.511.md)
- [1.0.510.md](changelog/archive/1.0.510.md)
- [1.0.509.md](changelog/archive/1.0.509.md)
- [1.0.508.md](changelog/archive/1.0.508.md)
- [1.0.507.md](changelog/archive/1.0.507.md)
- [1.0.506.md](changelog/archive/1.0.506.md)
- [legacy-unreleased.md](changelog/archive/legacy-unreleased.md)
