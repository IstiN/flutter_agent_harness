# herdr integration

[herdr](https://github.com/herdrdev/herdr) is a terminal multiplexer built
for coding agents: it owns agent PTYs (detached server, session restore,
remote machines), marks every pane `working / blocked / idle / done`, and
exposes a CLI + socket API so agents can spawn panes and wait on each
other. fa is a supported herdr agent through three seams — pane-state
detection, a skill install target, and session resume.

## 1. Pane detection — `fa.toml`

herdr classifies a fa pane from its screen with the detection manifest
`src/detect/manifests/fa.toml` (upstream). The canonical fa-side source of
that file lives in this repo: [`fa.toml`](fa.toml) — the manifest rules
are data, so this copy is reviewed and fixture-tested here first, then
merged upstream.

The rules key on fa's TUI chrome (TUI omp-parity epic #802, S3 band
composer #806):

| rule | state | keys on |
|---|---|---|
| `approval_sheet` / `secret_sheet` / `ask_sheet` / `host_menu_selection` | blocked (220/220/215/210) | bottom-anchored prompt frames: `+- Approval -`, `+- Secret -` (+ `Credential request`), `+- Ask -`, `waiting for your selection` |
| `composer_gutter` | idle (150) | S3 band-composer gutter `+- ` in the bottom rows — gated `not` on the live spinner so a streaming pane never reads idle |
| `classic_status_footer` | idle (130) | legacy chrome: full-width dim rule + `· ctx ` / `· turn ` footer — same spinner `not` gate |
| `busy_row` | working (120) | spinner prefix + elapsed tail (`12s`, `5m`, `2h05m`, `+`) — the `Working…` shimmer row or a phase row like `Compacting context...` |
| `working_literal` | working (100) | whole-buffer `Working...` fallback (pi-parity) |

Arbitration follows herdr's engine: highest-priority matching rule wins;
no match → idle. Idle rules carry `not` gates because the band composer
never unmounts — the gutter stays painted under the busy row.

`blocked` covers the four prompt-zone shapes (`tui_prompt.dart`):
approval sheets, the secret-request sheet, ask-tool question sheets, and
the host/model menu. A transcript QUOTING a sheet (e.g. fa explaining an
approval it once showed) does not block: the sheet rules read only the
bottom 24 non-empty rows, and transcripts scroll.

Fixture transcripts captured from the real renderers live in
[fixtures/](fixtures/) — sheet frames byte-checked against
`renderTuiPrompt`, working/idle/classic frames from the S3 and legacy
chrome. `test/integration/herdr_detection_test.dart` transliterates
herdr's matcher (regions, gates, priority arbitration) and asserts every
fixture classifies to its state, plus the arbitration edges (quoted
`Working...` stays idle, live spinner beats the gutter).

## 2. Skill install target — `~/.fah/skills/herdr/`

`herdr integration` installs the herdr agent skill into fa's USER-level
skills root — never project scope; the skill is machine-level tooling.
The canonical skill content ships here: [`SKILL.md`](SKILL.md). It is
first-party (`SkillSource.fah`), so it loads with no third-party-consent
prompt, and its body is guarded on `HERDR_ENV`: outside a herdr pane the
instructions are inert — a herdr-less machine with the same install
regresses nothing.

fa reads the skill from `$HOME/.fah/skills/herdr/SKILL.md` via the
standard discovery roots; `/skills` lists it and `/skill:herdr <args>`
invokes it. `HERDR_ENV=1` (set by herdr for every pane process) reaches
the bash tool through the environment, so the skill's herdr-CLI recipes
work inside the agent's shell too.

Tests: `test/integration/herdr_skill_test.dart` (discovery, rendering,
env passthrough, inert-without-herdr, resume — mock provider, no herdr
binary) and `test/integration/herdr_skills_pty_test.dart` (TUI
`/skills` + `/skill:herdr` wiring, `--tags pty`).

## 3. Session resume — `fa --session <id|name>`

herdr's pane restore re-attaches a killed fa session with
`fa --session <id|name>`: the spec resolves session id first, then
session name, then errors. Both surfaces are covered by the resume tests
in `herdr_skill_test.dart` — the second run's provider request carries
the first run's transcript.

No other fa-side changes are required for resume: ids and names are the
existing `--session` contract. (Session ids are the trailing part of the
session file name, `<timestamp>_<id>.jsonl` under `~/.fah/sessions/`.)

## Non-goals

- `--output events` as herdr's state source (upstream discussion, second
  tier) — the manifest is the v1 contract.
- fa↔fa pane orchestration through herdr's socket API — fa's own
  coverage engine covers agent-to-agent work.
- TUI changes — that is epic #802.
