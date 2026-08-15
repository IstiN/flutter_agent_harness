# Phase 4 — Agent-Type Menu: Filesystem Discovery + Memory-Backed Specs

**Status: done** (shipped on main).

Depends on: phase 1 (memory store), phase 3 (subagent runtime).

## Goal

The set of spawnable agent types stops being three hardcoded definitions
(`task` / `explore` / `review` in `lib/src/task/agent_registry.dart`) and
becomes an extensible menu — from markdown files on disk and, optionally,
from memory — rendered into the parent prompt so the model can pick the
right specialist, exactly like prime-agent's harness `subagent` entries and
Claude Code's Agent menu.

## Design

### 4.1 Filesystem discovery (planned follow-up, finally landed)

`TaskAgentRegistry` already supports host overrides by name; the missing
piece is discovery (explicitly marked "follow-up" in the current code).

- Roots, same convention as skills: project `.fah/agents/`,
  `.agents/agents/` > user `~/.fah/agents/`, `~/.agents/agents/`;
  first-name-wins.
- Format: one `<name>.md` per agent type, YAML frontmatter + body:

```markdown
---
name: security-review
description: Reviews diffs for security issues; read-only.
tools: [read, grep, glob, bash]   # optional allowlist
readOnly: true                    # optional, default false
modelRole: slow                   # optional: default|smol|slow|plan
---

You are a security reviewer… (system prompt body)
```

- `lib/src/task/agent_discovery.dart`:
  `Future<List<TaskAgentDefinition>> discoverTaskAgents(ExecutionEnv env,
  {projectRoots, userRoots})` — mirrors `discoverSkills`
  (`lib/src/skills/skills.dart`), strict frontmatter validation (unknown
  keys = skip with a note, never crash), `readOnly: true` ⇒
  `toolSurfaceFor` filters to `ApprovalTier.read` (existing logic).
- Discovery results merge: built-ins < user roots < project roots (project
  wins on name clash); host overrides in `TaskAgentRegistry` still win over
  everything.
- CLI command `/agents` — list the resolved menu with origin (built-in /
  user / project / memory).

### 4.2 Memory-backed specs (optional, small)

Subagent specs as memory entries (`kind = subagent` in the harness sense;
for us: a `Note` with `type: rule` + `tags: [agent-spec]` and structured
frontmatter is enough — do NOT invent a parallel store). On session start,
`MemoryController` exposes `agentSpecs()`; matches convert to
`TaskAgentDefinition`s at the lowest precedence (below files). This lets the
agent itself mint new specialist types with `memory_add` — the prime-agent
"self-refining harness" behavior, without a `/refine` command.

### 4.3 Prompt rendering

`prompts/tools/task.md` gets a `{{agentMenu}}` placeholder, filled at
composition time with the resolved menu:

```
Available agent types:
- explore — fast read-only codebase exploration (model: smol)
- review — read-only diff review (model: slow)
- security-review — Reviews diffs for security issues (project)
```

Metadata only, never bodies (progressive disclosure, same as skills). Menu
rebuilt when discovery roots change (fsRevision in the app; session start +
`/agents` in the CLI).

## Testing

- `test/task/agent_discovery_test.dart` — frontmatter parsing (all fields,
  defaults, malformed, unknown keys), root precedence, name clashes,
  readOnly filtering through `toolSurfaceFor`.
- `test/task/agent_menu_prompt_test.dart` — menu rendering, metadata-only,
  empty = placeholder omitted.
- Memory specs: note → definition conversion, lowest precedence, invalid
  spec skipped with a note.
- CLI `/agents` render test.

## Checklist

- [x] `lib/src/task/agent_discovery.dart` + roots convention + tests
- [x] Merge order: built-ins < user < project < host overrides (+ memory
      specs at the bottom)
- [x] `{{agentMenu}}` in `prompts/tools/task.md` + composition + tests
- [x] `MemoryController.agentSpecs()` → definitions (phase 1 dependency)
- [x] `/agents` CLI command
- [x] Docs: `docs/subagents/` updated, `AGENTS.md` task bullet amended
- [x] Gates green (analyze/format/tests/coverage/dup/CRAP)
