# Cross-platform parity

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Cross-platform parity

Every shared setting and interactive prompt type must exist on BOTH the CLI
(`lib/src/cli/`) and the Flutter app (`flutter_app/lib/`) unless it is
**fundamentally impossible** on the target platform. When a setting or prompt
type is platform-only (e.g. MCP servers need process spawning — impossible on
web), it MUST be explicitly listed in `cliOnlySettings` or `appOnlySettings`
in `lib/src/parity/settings_registry.dart` with a comment explaining WHY.

**Workflow when adding a new setting or interactive type:**
1. Add it to `SharedSetting` enum in `settings_registry.dart` FIRST
2. Implement on BOTH platforms (CLI + Flutter app)
3. If one platform genuinely cannot support it: add to the exemption set
   with a one-line reason comment
4. Run `dart test test/parity/` — the parity guard must pass

**Capability rules (issue #1079, host-wiring SDK layer):** every NEW
host-wiring capability declares its matrix state AT BIRTH — for all seven
hosts (`cli`, `macos`, `ios`, `android`, `web`, `extension`, `outlook`) a
state: `on`, `off(reason)`, or `transport(choice, reason)` for a
partial/different transport. The record types, validation and transport
vocabularies live in `lib/src/hosts/host_capability_profile.dart`; the
seven built-in profiles — where those per-host cells are actually
declared — live in `lib/src/hosts/host_wiring_builder.dart`. The
matrix-completeness test rejects undeclared capabilities, so "CLI got X,
app didn't" cannot happen silently. A capability that is
`off` is INVISIBLE: hidden from the host's UI (menus, settings, slash
commands, tool palettes) AND from everything model-facing (tool schemas,
system-prompt sections, skills listings, help) — the agent never sees
what it cannot use and the user never sees a button that errors; on a
`transport` cell only the available transports surface. Profiles can only
NARROW what the platform floor allows: force-enabling a floored
capability throws `HostProfileViolation` at construction, never a runtime
surprise.

**Host shells wire through the builder (issue #1079 slice 2):** a host
constructs its agent stack via `wireAgentCore` (lib/src/hosts/
host_agent_wiring.dart) — typed `AgentCoreServices` in, `WiredAgentCore`
(env chain + core tools + plan) and `buildAgentStack` (registry + agent)
out. The CLI (`AgentCli`) is the reference shell. Per-run narrowing:
a wired capability whose services the host did not provide turns
`off(reason)` for that run (a null config section is a declared state,
not a silent hand-rolled `if`), and wired transports with absent
per-transport services are dropped. When adding a capability: declare
every host's cell, add its `requiredServices` to the catalog, wire its
tools inside `wireAgentCore`'s canonical order, and extend the
hosts test — never gate tool registration with a bare `if` outside the
builder. The task/subagent complex (fabric → manager → heartbeat →
task/monitoring tools, slice 3) is builder-owned the same way: hosts pass
shell glue as `SubagentServices` callbacks and keep handles from
`WiredAgentCore` — a host never hand-assembles the manager or registers
`task` outside the gated surface. Host EXTENSIONS are declared surface
too (slice 4, `HostExtensionApi`, lib/src/hosts/host_extension_api.dart):
a `HostExtension` carries its tools plus an explicit state for every
built-in profile at birth (E6 — no implicit default; a custom profile
needs its state before wiring), the builder rejects tool-id collisions
across the core/task/extension surfaces at build time naming both
registrants (E7 — an extension id colliding with a core tool would
silently override SDK behavior, so the loud check lives in the builder,
not the child-lenient `ToolRegistry`), and an extension `off` on the
wired profile hides from the registry with its reason surfaced on
`WiredAgentCore.extensions` (E8). The extension surface is additive-only:
memory, context management, compaction, the JSONL tool session and
trajectory are SDK invariants with no override point (AC9). The
flutter_app is the second shell (slice 5): it wires through
`flutterAppHostProfile` (lib/src/hosts/app_host_profile.dart — the app
host's own honest today-state, not the built-ins, whose cells pin the
matrix TARGET) and packages its platform tool families as a declared
`app-platform` extension — per-platform conditioning stays construction
glue in the shell, never a bare `if` around registration. Capabilities
the builder registers no tool for are declared with PRESENCE MARKER
services (`dynamicMessageSink`, `onDeviceProviderFactory`, the
`extRuntimeFactory` precedent): the host's extension carries the tool,
the marker keeps the cell honestly wired instead of run-narrowing off.
A host whose session scope differs from `ExecutionEnv.cwd` (the app's
mounted project folders) passes `sessionCwd` so the fabric groups mail by
workspace.

