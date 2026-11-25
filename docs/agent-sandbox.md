# Agent sandbox — isolated arms for A/B agent tests

Tooling: [`scripts/agent-sandbox/`](../scripts/agent-sandbox/). macOS only
(`sandbox-exec`, Keychain). Goal: a test arm must not read other agents'
contexts, the operator's sessions or the machine's files — otherwise the test
measures the leak, not the agent (round-1 evidence: an arm read the operator
session through the shared store).

## Leak channels and how each one is closed

| Channel | Closed by |
| --- | --- |
| Machine-wide session store (macOS default `~/Library/Group Containers/group.dev.fa1.shared/fa/sessions`; `$HOME` does not switch it) | explicit `--session-root <arm home>/sessions` — always |
| `session_search`, `memory_*`, `agent_message`/`agent_directory`, `web_search` | `--tools …=off` deny list |
| Memory roots (`<cwd>/.fah/memory`, `~/.fah/memory`) | per-arm `HOME` + `cwd` (verified: memory lands in the arm only) |
| `GH_TOKEN`/`GITHUB_TOKEN`/`*_TOKEN`/`SSH_AUTH_SOCK` | `env -i` |
| `find /`, `mdfind`, shared `/tmp`, neighbour dirs, fixture origin | seatbelt profile (writes denied everywhere except the arm root and `/dev`; reads of `/Users`, `/private/tmp`, `/private/var/tmp`, `/private/var/folders`, `/Volumes` denied; Spotlight denied) + fixture copied without `origin` |

Pitfalls found while building it:

- `allowedTools` in `config.yaml` is the **approval** always-allow list, not a
  tool allowlist. fa has no allowlist: every non-core family is switched off
  via `tools:`/`--tools`/`FA_TOOLS` (`lib/src/tools/availability.dart`).
- `agent_message`, `agent_directory`, `reply` belong to the `task` family:
  `task=off` is the only switch.
- Under a foreign `HOME` the Keychain is not readable; the provider key is
  passed in env. `--provider zai` alone does not take it — use
  `FA_PROVIDER_TYPE` + `FA_PROVIDER_CONFIG` (see `fa --help`).
- The prompt file and anything else the arm needs must be copied into the arm
  root — the profile denies everything else.

## Usage

    scripts/agent-sandbox/run_arm.sh <arm-id> <prompt.md> [fa args]

Knobs: `ARM_ROOT` (must match `/tmp/fa-arm-*`), `FIXTURE`, `ARM_TOOLS_EXTRA`
(csv, e.g. `task=on` for arms with subagents), `ARM_NO_SBX=1` (drop the wall),
`ARM_UNSAFE=1` (drop `--session-root`). The last two exist for positive
controls only.

## Verification (after ANY change here, or an fa/macOS upgrade)

    scripts/agent-sandbox/verify_sandbox.sh control   # wall removed: canaries MUST leak
    scripts/agent-sandbox/verify_sandbox.sh attack    # prompt orders reads of canaries: blocked
    scripts/agent-sandbox/verify_sandbox.sh sandbox   # tempting prompt + real task: clean + solved

Canaries: `CANARY-OPERATOR` (emulated operator session store — real sessions
are never modified), `CANARY-SIBLING` (a sibling arm's session), `CANARY-DECOY`
(decoy repo with a half-done solution), `CANARY-FS` (loose file in `/tmp`),
`CANARY-VARTMP` (loose file in `/private/var/tmp`); all are the
freshest files on disk and carry a per-run random suffix.
`check_trace.py` parses the arm trace: tool surface offered to the model (V1),
canaries anywhere under the arm root/log (V5), paths outside the sandbox in
tool calls (V6, a WARN when the wall blocks them; `STRICT=1` fails), foreign
references (V7). `verify_sandbox.sh` adds V2 (provider key never in the trace;
in attack/control the arm lists its env and no GitHub/SSH variable may appear),
V3 (session in the arm; real stores untouched: files written during the run that
mention the run id — a live operator session does not trip it), V4 (real memory
untouched, same rule), V8 (write probe into `/private/var/tmp` must fail), and
TASK-solved (the pristine fixture tests run on a copy of the arm's work inside
the same seatbelt profile and env, so arm-written code never runs with operator
privileges and the arm cannot pass by editing the tests). The `control`
run is inverted: it passes only if the canaries leaked (V5), proving the
detector; any other failure still fails it.

## Known residuals

- `ZAI_API_KEY` is visible to the arm via `env` (never found in traces). Use a
  dedicated, revocable key.
- Egress is open: seatbelt cannot allowlist hosts. A real allowlist needs a
  container or GitHub runners.
- `sandbox-exec` is deprecated by Apple — re-run the verification after macOS
  updates.
- Remaining tools: read, write, edit, ls, bash, bash_job, config, decide,
  task_resume, checkpoint, rewind, compact_expand.

## Not done

GitHub-runner finals (fixture repo + workflow) and upstream harness changes
(non-interactive runs falling back to the machine-wide store, memory root
following `HOME`, a sandbox-profile config key, a real tool allowlist) are
deliberately out of scope here.
