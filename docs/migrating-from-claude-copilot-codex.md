# Migrating from Claude Code, GitHub Copilot, or OpenAI Codex

Fa reads your existing agent configuration **in place** — nothing is copied,
converted, or moved. If a project (or your home directory) already has
skills, commands, agents, or instruction files from another tool, Fa picks
them up at startup once you allow it.

## The consent gate

Third-party directories contain instructions and scripts written for other
tools, so Fa never reads them silently:

- **First startup with such directories present** (interactive): a one-time
  dialog — *Allow* (remembered), *Not now* (asked again next launch),
  *Never* (remembered). The Flutter app shows the same choice as an
  onboarding page / one-time dialog.
- **Headless runs** (`fa -p …`): undecided means *not read* (safe default);
  a stderr hint tells you how to enable them.
- **Change anytime**: CLI `/skills access ask|granted|denied`, app
  Settings → Skills access. Persisted in `~/.fah/config.yaml` (`skills:
  access:`) for the CLI and `skills_access.json` for the app.

Fa's own roots (`.fah/skills`, `.agents/skills`, `.fah/agents`,
`.agents/agents`) are always read — the gate only covers other tools'
directories.

## What is picked up

| Tool | Skills | Agents / subagents | Instruction files |
|---|---|---|---|
| Claude Code | `.claude/skills/*/SKILL.md`, `~/.claude/skills`, `.claude/commands/*.md` | `.claude/agents/*.md`, `~/.claude/agents` | `CLAUDE.md` |
| GitHub Copilot | `.github/skills`, `~/.copilot/skills` | `.github/agents/*.agent.md` | `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` |
| OpenAI Codex | `.codex/skills`, `~/.codex/skills` | `.codex/agents`, `~/.codex/agents` | `AGENTS.md` (native to Fa) |
| Gemini CLI | — | — | `GEMINI.md` |

Project roots win name clashes over user roots, first name wins; Fa's own
roots take precedence over third-party ones. (Note: Claude Code itself
prefers user-level over project-level on clashes — Fa keeps its
project-first rule.)

## Skills: using them

- List: `/skills` (CLI) — shows name, description, location, source
  (`claude`/`copilot`/`codex`) and flags (`model-only`, `user-only`,
  `fork`, `path-gated`).
- Invoke: `/skill:<name> [args]` or the Claude-style alias
  `/<name> [args]`.
- The model sees skill metadata in the system prompt and loads bodies on
  demand (progressive disclosure), same as native Fa skills.

### Supported frontmatter

`name`, `description`, `when_to_use`, `argument-hint`, `arguments`,
`disable-model-invocation`, `user-invocable`, `allowed-tools`,
`disallowed-tools`, `model`, `effort`, `context: fork`, `agent`,
`background`, `paths`, `shell`, `license`, `compatibility`, `metadata`,
`applyTo` (Copilot), `excludeAgent` (ignored). Unknown keys produce a
discovery note, never a crash.

### Invocation semantics

- `$ARGUMENTS`, `$ARGUMENTS[N]`, `$0..$9`, named `$name` (from `arguments:`)
  and `${CLAUDE_SESSION_ID}` / `${CLAUDE_PROJECT_DIR}` / `${CLAUDE_SKILL_DIR}`
  are substituted; `\$` escapes. With no placeholder, raw args are appended
  as `ARGUMENTS: …`.
- `` !`cmd` `` lines and ```` ```! ```` fenced blocks run through the shell
  before the content reaches the model (2-minute timeout per command; a
  failing command aborts the invocation). Disable globally with
  `skills: disableShellExecution: true` in `~/.fah/config.yaml`.
- `allowed-tools: [Read, Bash]` becomes a **per-turn approval grant** (and
  `disallowed-tools` a per-turn deny) on Fa's approval gate; grants clear on
  the next regular user message. Patterns with parentheses
  (`Bash(git fetch:*)`) cannot be mapped onto Fa's tool-name gate and are
  reported as a note instead of being granted.
- `context: fork` runs the rendered skill as a subagent (the `task` tool);
  `agent:` picks the agent type (Claude's `Explore`/`Plan`/`general-purpose`
  names are folded onto Fa's `explore`/`plan`/`task` types), `background:
  true` makes it a background job whose completion re-enters as a message.
- `paths:` (Claude path-gated skills) keeps the skill out of the prompt
  until the agent has touched a matching file this session.
- `hooks` are not executed (Fa has no hook runner); they are reported as a
  discovery note.

## Agents (subagent types)

`<name>.md` (Claude/Codex layout) and `<name>.agent.md` (Copilot) files
define agent types for the `task` tool: frontmatter `name`, `description`,
`tools` (list or comma string; `*` = full surface, `[]` = none),
`readOnly`, `modelRole` (or Claude's `model` when it names a Fa role). The
body becomes the subagent's system prompt. `/agents types` lists them;
discovered names like `Reviewer` override the matching built-in.

Copilot specifics: `target: vscode` profiles are skipped (VS Code-only),
`mcp-servers` is reported as unsupported, `argument-hint`/`handoffs` are
ignored (IDE-only).

## Instruction files

`CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md` and
`.github/instructions/*.instructions.md` merge into the system prompt along
the existing `AGENTS.md` walk (working directory → git root,
farthest-first, 32 KiB leaf-first budget). Copilot `applyTo` globs are not
evaluated — scoped files are included with an `<!-- applies to: … -->`
marker instead.

## Optional: taking ownership

`/skills import` copies discovered third-party skills into
`.fah/skills/<name>/SKILL.md` (name clashes with existing own skills are
skipped). Only the manifest file is copied — auxiliary skill files stay
with the original directory. After import the skills no longer depend on
the consent gate.
