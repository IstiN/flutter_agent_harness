# herdr integration

[herdr](https://github.com/herdrdev/herdr) is a terminal multiplexer built
for coding agents: it owns agent PTYs (detected server, session restore,
remote machines), marks every pane `working / blocked / idle / done`, and
exposes a CLI + socket API so agents can spawn panes and wait on each
other. fa is a supported herdr agent through three seams — the pane-state
reporter (v2, primary), a skill install target, and session resume. The
screen-scrape detection manifest survives as a demoted second tier.

## 1. Pane state — `HerdrReporter` (v2, self-report)

fa reports its own pane state to herdr: a session running inside a herdr
pane keeps herdr's record of that pane true for the whole life of the pane
and releases cleanly on exit. The v1 framing — herdr detects fa by
screen-scraping a detection manifest merged upstream — is retracted: that
manifest never landed in herdrdev/herdr, and a real fa session in a herdr
pane sat at `agent_status: "unknown"` while these docs claimed support.

`HerdrReporter` (`lib/src/cli/herdr_reporter.dart`) owns exactly one job:
reporting the pane named by `HERDR_PANE_ID` to the binary named by
`HERDR_BIN_PATH`. Every report is one fire-and-forget subprocess of
`"$HERDR_BIN_PATH" pane …` with a short timeout, silent on failure — a
dead herdr is indistinguishable from no herdr (no retry, no queue, no log
line, no user-visible output).

**Gate** — the reporter is active only when `HERDR_ENV=1` AND
`HERDR_PANE_ID` is set and charset-valid (`[A-Za-z0-9._-]+`) AND
`HERDR_BIN_PATH` is set, absolute, and argv-safe, AND the kill switch is
not engaged (`FA_HERDR=0`). herdr exports the vars to every pane process,
so the CLI reads its own process env; `FA_HERDR=0` turns the integration
off per-pane or per-machine. Any unmet condition is byte-identical to no
herdr: the reporter is constructed inert and spawns nothing for the
process lifetime. A herdr-less machine regresses nothing.

**State machine** (subject: fa's own pane, as herdr records it):

| fa event | herdr state | report |
|---|---|---|
| REPL boot, composer resting | `idle` | `pane report-agent <pane> --source fa --agent fa --state idle --seq <ms>` — sent once at boot so the pane never sits `unknown` |
| run/turn start | `working` | same shape, `--state working` |
| approval sheet visible | `blocked` | `--state blocked --message approval` |
| ask-tool question sheet | `blocked` | `--message ask` |
| secret-request sheet | `blocked` | `--message secret` |
| host/model & input sheets | `blocked` | `--message host-model` |
| prompt resolved | `idle`/`working` per the rows above | — |
| in-process session switch (`/session`, `/new`, the picker) | re-report | `pane report-agent-session … --agent-session-id <id>` — never a release |
| REPL shutdown (`/exit`, EOF) | (release) | `pane release-agent <pane> --source fa --agent fa --seq <ms>` |

Invariants: reports fire on transition (no polling, no heartbeat);
`--seq` is a millisecond timestamp forced strictly increasing (herdr
requires seq to rise across ALL reports from one source, including across
restarts — a timestamp survives them, an in-memory counter does not);
every report carries `--agent-session-id <id>` (the `--session` contract's
session id) and, once per session, the resume argv `-- fa --session <id>`
that herdr ≥0.10.0 uses to restore a killed pane (older herdr silently
ignores the resume argv while state/release still work — pinned
asymmetry, never "fixed" away). If fa dies without releasing (SIGKILL),
herdr's own safety net clears the registration once the pane is back at a
shell prompt.

**Labels are static.** The `--message` value comes from a closed
4-value enum (`approval` / `ask` / `secret` / `host-model`), the state
from a 3-value enum — no transcript text, no user text, no file paths,
no secrets can ever reach a report argv (byte-scanned in
`test/cli/herdr_reporter_test.dart`). The reporter reads nothing from
herdr: no screen scraping, no socket listens, no sibling-pane queries —
one-way only.

Tests: `test/cli/herdr_reporter_test.dart` (gate truth table, argv
builders, charset + resume-argv rules, seq discipline, failure silence,
payload byte-scan) and `test/cli/herdr_reporter_lifecycle_test.dart`
(reports through a real `AgentCli.run` — ordering, release-once,
session-switch, inert-gate zero-spawn, canary scan). The transport is an
injected `Process.run` closure (`bin/fah_runapp.dart`); lib/ stays
dart:io-free.

## 2. Pane detection — `fa.toml` (second tier)

herdr can still classify a fa pane from its screen with the detection
manifest `src/detect/manifests/fa.toml` (upstream). The canonical fa-side
source of that file lives in this repo:
[`fa.toml`](herdr/fa.toml). The manifest is demoted to second tier: it
still works where the reporter cannot run (someone else's fa build, an
older release), and the upstream merge stays follow-up-friendly. It is
NOT the v1 "contract" — self-report is.

The rules key on fa's TUI chrome (TUI omp-parity epic #802, S3 band
composer #806):

| rule | state | keys on |
|---|---|---|
| `approval_sheet` / `secret_sheet` / `ask_sheet` / `input_sheet` | blocked (220/220/215/215) | bottom-anchored prompt frames: `+- Approval -`, `+- Secret -` (+ `Credential request`), `+- Ask -`, and the provider-wizard / `/key` prompts `+- Input -` / `+- Password -` |
| `host_menu_selection` | blocked (210) | the host/model picker's `waiting for your selection` cue |
| `composer_gutter` | idle (150) | S3 band-composer gutter `+- ` in the bottom rows — gated `not` on the live spinner so a streaming pane never reads idle |
| `classic_status_footer` | idle (130) | legacy chrome: full-width dim rule + `· ctx ` / `· turn ` footer — same spinner `not` gate |
| `busy_row` | working (120) | spinner prefix + elapsed cell (`12s`, `6h00m`, `99h+`) with the provenance suffix optional (`12s · run`, `· quiet Nm`) — the `Working…` shimmer row or a phase row like `Running bash…` / `Compacting context…` |
| `working_literal` | working (100) | whole-buffer `Working…` fallback (pi-parity) |

Arbitration follows herdr's engine: highest-priority matching rule wins;
no match → idle. Idle rules carry `not` gates because the band composer
never unmounts — the gutter stays painted under the busy row.

A transcript QUOTING a sheet (e.g. fa explaining an approval it once
showed) does not block: the sheet rules read only the bottom 24 non-empty
rows, and transcripts scroll. For the reporter that false-positive class
is structurally gone (it reads no screen); the fixtures keep covering it
for the manifest path.

Fixture transcripts captured from the real renderers live in
[fixtures/](herdr/fixtures/) — sheet frames byte-checked against
`renderTuiPrompt`, busy rows byte-checked against the live frame painter
(`FaTuiModel.view()`, the seam the busy-row unit test pins), idle/classic
context shaped by the S3 and legacy chrome.
`test/integration/herdr_detection_test.dart` transliterates
herdr's matcher (regions, gates, priority arbitration) and asserts every
fixture classifies to its state, plus the arbitration edges (quoted
`Working...` stays idle, live spinner beats the gutter).

## 3. Skill install target — `~/.fah/skills/herdr/`

`herdr integration` installs the herdr agent skill into fa's USER-level
skills root — never project scope; the skill is machine-level tooling.
The canonical skill content ships here: [`SKILL.md`](herdr/SKILL.md). It is
first-party (`SkillSource.fah`), so it loads with no third-party-consent
prompt, and its body is guarded on `HERDR_ENV`: outside a herdr pane the
instructions are inert — a herdr-less machine with the same install
regresses nothing.

fa reads the skill from `$HOME/.fah/skills/herdr/SKILL.md` via the
standard discovery roots; `/skills` lists it and `/skill:herdr <args>`
invokes it. `HERDR_ENV=1` (set by herdr for every pane process) reaches
the bash tool through the environment, so the skill's herdr-CLI recipes
work inside the agent's shell too. Sibling-pane queries remain the
skill's job (the user-invoked herdr CLI) — the reporter itself never
reads herdr.

Tests: `test/integration/herdr_skill_test.dart` (discovery, rendering,
env passthrough, inert-without-herdr, resume — mock provider, no herdr
binary) and `test/integration/herdr_skills_pty_test.dart` (TUI
`/skills` + `/skill:herdr` wiring, `--tags pty`).

## 4. Session resume — `fa --session <id|name>`

herdr's pane restore re-attaches a killed fa session with
`fa --session <id|name>`: the spec resolves session id first, then
session name, then errors. With the reporter running, herdr learns the
current session id (and the static resume argv) from fa's own reports —
a restored pane re-attaches the transcript with no extra fa-side wiring.
Without the reporter (older fa builds), `herdr integration`'s resume plan
resolves the pane's session from the skill's guidance instead. Both
surfaces are covered by the resume tests in `herdr_skill_test.dart` — the
second run's provider request carries the first run's transcript.

Ids and names are the existing `--session` contract. (Session ids are the
trailing part of the session file name, `<timestamp>_<id>.jsonl` under
`~/.fah/sessions/` — the same id every reporter report carries.)

## Non-goals

- Socket transport (`pane.report_agent` over herdr's socket API) — the
  CLI subprocess path is blessed and cheap; socket parity is a
  follow-up if it ever bottlenecks.
- No retry, no queue, no heartbeat — dropped reports stay dropped;
  herdr's last-known state stands until fa's next transition heals it.
- Headless `-p` reporting parity — second tier; the reporter is scoped
  to the interactive CLI lifecycle.
- `--output events` (HEP) as herdr's state source — retired with the v1
  framing; self-report supersedes it.
- fa↔fa pane orchestration through herdr's socket API — fa's own
  messaging fabric covers agent-to-agent work.
- TUI changes — that is epic #802; the reporter removes the dependency
  of pane state on chrome.
- The upstream `fa.toml` merge and the `herdr integration install fa`
  target — herdr-side, blocked on the same upstream PR; the in-repo copy
  and its tests stay green in the meantime.
