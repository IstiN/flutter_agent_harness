# docs/ — canonical documentation index

Every subsystem essay moved out of `AGENTS.md` (gh-2181) landed here; the
slim `AGENTS.md` carries one-line summaries + `→ docs/...` pointers. New
docs must be listed in this index (pinned by
`test/docs_link_check_test.dart`). This index file itself is
`docs/README.md`.

## Agent entry / conventions (docs/agents/)

| Doc | Covers |
| --- | --- |
| [docs/agents/sdk-subsystems.md](agents/sdk-subsystems.md) | `lib/` subsystem reference (approval, tools, env, agent, trajectory, redact, hashline, compaction, lsp, mcp, model_roles, ttsr, skills, prompts, task, messaging, memory, a2a, cli, cube, hep, web_search, fa-clip) |
| [docs/agents/flutter-app-subsystems.md](agents/flutter-app-subsystems.md) | `flutter_app/` UI/services/sandbox/goldens + `packages/fa_ui`, `site/`, `scripts/`, `docs/subagents/` pointers |
| [docs/agents/parallel-worktrees.md](agents/parallel-worktrees.md) | shared-checkout policy, worktree placement rules |
| [docs/agents/memory-usage.md](agents/memory-usage.md) | memory scopes, `memory_add` policy, host wiring |
| [docs/agents/golden-tests.md](agents/golden-tests.md) | the golden-test mandate (coverage, fonts, frames, determinism, gates) |
| [docs/agents/prompts.md](agents/prompts.md) | prompts-outside-Dart policy + codegen scripts |
| [docs/agents/quality-gates.md](agents/quality-gates.md) | CI layout, gate stages, coverage/CRAP/duplication ratchets, flake quarantine |
| [docs/agents/cross-platform-parity.md](agents/cross-platform-parity.md) | CLI/app parity + the 7-host capability matrix |
| [docs/agents/commits-releases.md](agents/commits-releases.md) | commit identity, tagging, release draft/provenance, store pipelines, lockfiles |
| [docs/agents/cli.md](agents/cli.md) | `fah`/`fa` CLI machinery, `/settings` hub, provider catalog |
| [docs/agents/fa-ui.md](agents/fa-ui.md) | `packages/fa_ui/` reusable widget package |
| [docs/agents/flutter-app.md](agents/flutter-app.md) | Flutter app structure, shim re-exports, widgets |
| [docs/agents/js-apps.md](agents/js-apps.md) | JS apps platform, demo apps, runtime pinning |
| [docs/agents/project-layout.md](agents/project-layout.md) | top-level tree + condensed subsystem map |
| [docs/agents/providers.md](agents/providers.md) | provider auth flows (chatgpt / codemie / dial / openrouter) |
| [docs/agents/services.md](agents/services.md) | Flutter app services one-liner |
| [docs/agents/system-integrations.md](agents/system-integrations.md) | HomeKit, Calendar, CodeMie SSO |

## Core runtime & protocols

- [docs/compaction.md](compaction.md) — compaction policy (AutoCompactor, branch summaries)
- [docs/memory-churn.md](memory-churn.md) — long-term memory policy: durable facts, supersede, churn pitfalls
- [docs/dap.md](dap.md) — DAP hub (debug adapters, fa_network bridging caveats §14)
- [docs/cubes.md](cubes.md) — fa_cube sandbox profiles
- [docs/redaction.md](redaction.md) — layered secret redaction
- [docs/hep.md](hep.md) — HEP v1 harness event protocol
- [docs/wire-protocol.md](wire-protocol.md) — wire protocol (framing, extensions)
- [docs/embedding.md](embedding.md) — embeddings subsystem
- [docs/media-models.md](media-models.md) — media model slots (image/audio/video)
- [docs/proxy.md](proxy.md) — proxy support
- [docs/logging.md](logging.md) — logging architecture
- [docs/tool-availability.md](tool-availability.md) — tool availability gating families
- [docs/backend-agent-mode.md](backend-agent-mode.md) — backend agent mode
- [docs/session-hygiene.md](session-hygiene.md) — session hygiene rules
- [docs/js-extensions.md](js-extensions.md) — JS extension registry
- [docs/js-system-apis.md](js-system-apis.md) — JS system APIs
- [docs/codex_websocket_adapter.md](codex_websocket_adapter.md) — Codex websocket adapter
- [docs/migrating-from-claude-copilot-codex.md](migrating-from-claude-copilot-codex.md) — migration guide

## Surfaces & platforms

- [docs/browser-extension.md](browser-extension.md) — Chrome MV3 extension + bridge (layout details moved in from AGENTS.md)
- [docs/browser-extension-permissions.md](browser-extension-permissions.md) — extension permission surface
- [docs/outlook-addin.md](outlook-addin.md) — Office/Outlook add-in (fa_office_agent, FA_HOST=office)
- [docs/integrations/herdr.md](integrations/herdr.md) — herdr integration
- [docs/android-automation.md](android-automation.md) — Android automation
- [docs/android-readiness.md](android-readiness.md) — Android readiness
- [docs/web-rehosting.md](web-rehosting.md) — web rehosting

## Delivery, CI & performance

- [docs/ci.md](ci.md) — CI workflows, release train, SM validation
- [docs/ci-merge-queue-research.md](ci-merge-queue-research.md) — merge-queue research notes
- [docs/bench.md](bench.md) — bench harnesses + round-3 timeout knobs (moved in from AGENTS.md)
- [docs/performance-cli-tui.md](performance-cli-tui.md) — CLI/TUI performance
- [docs/live-llm-testing.md](live-llm-testing.md) — live-model testing policy
- [docs/leaderboard-submission.md](leaderboard-submission.md) — leaderboard submissions
- [docs/github_widgets_oauth.md](github_widgets_oauth.md) — GitHub widgets OAuth
- [docs/images.md](images.md) — image handling

## Plans

- [docs/subagents/README.md](subagents/README.md) — subagents-2.0 + long-term-memory master plan (phased phase-0…phase-5 docs)
- [docs/widgets/GOAL.md](widgets/GOAL.md) — widgets goal
