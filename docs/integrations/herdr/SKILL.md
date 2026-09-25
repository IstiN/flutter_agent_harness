---
name: herdr
description: >
  Drive the herdr terminal multiplexer from inside fa: report on sibling
  agent panes, wait until another agent is genuinely blocked, spawn panes
  and prompt other agents through the herdr CLI/socket API. Only act when
  actually running inside herdr (HERDR_ENV=1); say so and carry on alone
  otherwise.
when_to_use: When HERDR_ENV=1 and the task needs sibling agents — inspecting
  pane states, waiting on a blocked agent, spawning or prompting panes.
  Never for solo work — without herdr on PATH the skill is inert.
argument-hint: "[what to check or run, e.g. 'who is blocked and why']"
allowed-tools:
  - bash
user-invocable: true
disable-model-invocation: false
---

# herdr

You may be running inside a [herdr](https://herdr.dev) pane — a terminal
multiplexer that owns agent PTYs and marks every pane `working / blocked /
idle / done`.

## Guard — read this first

If `$HERDR_ENV` is not `1`, you are NOT inside herdr: this skill is inert.
Do not install, probe for, or mention herdr; carry on without it.

Verify from the bash tool (`herdr` calls are ordinary exec-tier commands,
so the user's approval settings apply):

```bash
printf 'herdr=%s' "$HERDR_ENV"
```

## What herdr gives you

- `herdr list` — panes with agent ids and states (`working`, `blocked`,
  `idle`, `done`, `unknown`). `blocked` means a sibling agent is waiting on
  a human — herdr exists to surface exactly that; do not busy-poll it.
- `herdr spawn <agent> [prompt]` — start a new agent pane.
- `herdr prompt <pane> <text>` — send a prompt to a pane.
- `herdr wait <pane> --state blocked` — block until a pane reaches a state
  (use a timeout; never wait forever).

## Working with siblings

1. `herdr list` first; address panes by their id, never by guessing.
2. To hand work over: `herdr prompt <pane> '…'` then
   `herdr wait <pane> --state blocked --timeout 300`.
3. A sibling's `blocked` screen holds its question — surface it to the
   user verbatim; the user answers in the pane, not through you.
4. Your own state is derived from fa's chrome (busy row, prompt sheets,
   `╰─ ` gutter), so answer prompts in the TUI promptly — that is what
   flips this pane from `blocked` back to `working`.

## Escalation

If `herdr` is on PATH but every command fails, report the first error and
stop — the pane may be running outside the herdr server's reach.
