# Embedding the harness in a host app (`wireAgentCore`)

This is the canonical path for embedding the harness **in-process** — a
desktop/Flutter host that owns the UI and drives the agent through the SDK
(the YoClip Studio / thin-client shape). The CLI (`bin/fah.dart`) is itself
just the first host shell built on exactly this layer
(`lib/src/hosts/host_agent_wiring.dart`), so everything here is the
documented, exercised surface — not an internal one.

## The one rule: `wireAgentCore` is the host path

**Do not build agents on `adk_dart` in a host.** Its `Runner` has **no
abort API and no timeout hooks** — a host can only drop chunks while the
request keeps running, and a wedged provider call hangs the host with no
recovery. `adk_dart` remains for its own legacy flows; hosts embed through
`wireAgentCore`, which gives every item below by default:

| Facility | Default | Where it is wired |
| --- | --- | --- |
| Run-idle watchdog | 8 min of event silence outside tool execution → cancel + `onRunIdleTimeout` | `Agent.runIdleTimeout` / `AgentWiringSpec.onRunIdleTimeout` |
| Provider connect timeout | 180 s | provider adapters (`providerStreamFunction`) |
| Provider stream-idle watchdog | 300 s mid-stream gap | provider adapters |
| Stuck-tool supervision + heartbeats | off; opt in | `AgentWiringSpec.stuckTool` |
| Cancel tokens | every run carries one | `agent.cancelToken` / `agent.abort()` |
| Lifecycle telemetry | opt in, one line | `AgentCoreServices.telemetry` |
| Key-slot resolution | opt in, one line | `AgentCoreServices.keyResolver` |

## Zero to agent

```dart
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

// 1. The provider leg: a StreamFunction over the catalog adapters.
final streamFn = providerStreamFunction(
  'openai-completions',   // kind: openai-completions, zai, anthropic, google, …
  apiKey,                 // resolved per the key section below
);

// 2. The services bundle: what YOUR host provides. Absent facilities are
//    declared `off` by run-narrowing — they never half-wire.
final services = AgentCoreServices(
  baseEnv: myExecutionEnv,                 // required: the env tools run in
  sessionEnvVars: () => mySessionVars,     // optional
  sandbox: const SandboxServices(spec: myCubeSpec, homeDir: home), // optional
  // keyResolver / telemetry — see the sections below
);

// 3. Wire the core: capability-gated tool list + env chain + plan.
final wired = wireAgentCore(profile: cliProfile, services: services);

// 4. Build the agent stack for this run.
final stack = wired.buildAgentStack(
  spec: AgentWiringSpec(
    model: myModel,                        // a catalog-resolved Model
    systemPrompt: 'You are the YoClip assistant.',
    onRunIdleTimeout: (error) => showRecoveryUi(error), // watchdog fired
    onRunWatchdogPaused: () => dimBusyRow(),            // relief compaction
  ),
  streamFunction: streamFn,
  additionalTools: myHostTools,            // your own AgentTools, if any
);

// 5. Drive it. Cancel is a method call, not a dropped subscription.
final run = stack.agent.prompt('cut the last 30 seconds and add captions');
// …user hit stop:
stack.agent.abort();
await run;
await stack.agent.waitForIdle();
```

What you keep vs what the SDK owns:

| Host keeps | SDK owns |
| --- | --- |
| UI, busy rows, streaming text rendering | the agent loop, turns, tool-call plumbing |
| your tools (as `AgentTool`s in `additionalTools`) | the canonical tool set, capability gating, env chain |
| message bus / session persistence choices | watchdog, timeouts, stuck-tool supervision, cancel |
| provider key storage (Keychain / SharedPreferences) | the resolution chain that names the correct slot |
| where telemetry lines go | the phase map, durations, HTTP status extraction |

## Provider keys: ask which slot resolves before you bind (Gap 2)

The CLI resolves provider keys through one chain (genuine env value →
endpoint-scoped `FA_KEY_<HOST>` slot → legacy env-name slots) and prints
migration hints when a **pinned** slot won over the canonical one. Hosts
drift when they guess: binding the canonical `FA_KEY_API_KIMI_COM` while
the Keychain holds the by-design pinned twin `FA_KEY_API_KIMI_COM_IRA_1`
"looks connected" and then 512-s hangs on an empty slot.

The SDK exposes the same chain as a pure service — **you inject your own
store readers** (Keychain, SharedPreferences, in-memory); the SDK never
touches platform storage:

```dart
final services = AgentCoreServices(
  baseEnv: env,
  keyResolver: HostKeyResolver(
    envRead: (name) => myEnv[name],          // your env / dotenv / dart-defines
    storeRead: myKeychain.read,              // your secure store
  ),
  onKeySlotDrift: (hint) => myUi.showBanner(hint), // the CLI's own hint text
);

// Anywhere, before binding a session:
final resolution = services.resolveKey(
  provider: 'kimi',
  baseUrl: 'https://api.kimi.com',
  model: model.id,
);
if (resolution != null && resolution.slotName == null) {
  myUi.showBanner(resolution.missingKeyHint!);  // names the slot to set
}
```

`resolveKey` returns the **effective slot name** the request path will use
(or null), the canonical `FA_KEY_<HOST>` name, and — when a pinned twin
(`<canonical>_…`) is winning — a drift hint identical to the CLI's
(`/key set <canonical> <value>`, then `/key delete <pinned>`). If you
supply a `keyResolver`, `buildAgentStack` also runs this check for the
run's model and fires `onKeySlotDrift` once — the same boot-time nag the
CLI prints, with one line of host code. That automatic check is
**store-only** (it has no catalog facts); a host that runs a catalog env
var alongside a pinned store twin should call `resolveKey` itself with
`envNames:`/`defaultBaseUrl:` and treat the boot-time hint as store-scope.

Store-only resolution note: without catalog facts (`envNames` /
`defaultBaseUrl`) the resolver is store-only by design, so the env leg can
never hijack a custom endpoint.

## Telemetry: the CLI's fa.log fidelity in-process (Gap 3)

A hung LLM call used to show "thinking 181 s" with zero lines anywhere.
Wire the sink once and every phase lands where the CLI's `fa.log` lands:

```dart
import 'package:flutter_agent_harness/io.dart';   // the file sink (dart:io)

final services = AgentCoreServices(
  baseEnv: env,
  // sid=<tag> lands on every line — the CLI's own lines always name their
  // session, so interleaved host/CLI processes stay attributable.
  telemetry: FileAgentTelemetrySink.forHomeDir(home, tag: 'yoclip-1'),
  // ... or your own sink over the pure interface:
  // telemetry: myAnalyticsSink,
);
```

Records (`AgentTelemetryEvent`): `runStart`, `turnStart`, `requestStart`
(the exact moment a provider call begins), `firstToken` (the provider
answered — a hang after `requestStart` is inbound), `toolStart`/`toolEnd`
(per call, with `isError`), heartbeats/stuck-call forensics (with
`outputBytes`/`attempt`), and `turnEnd` (stop reason). Aborted runs — a
user stop or a watchdog fire — are phase outcomes, not failures: they
render as the CLI's plain `run end` with `turn end stop=aborted`, never a
`run error` line. `error` records carry the FAILED request's duration and
provider HTTP status when the harness has it (typed `ProviderHttpError`,
or parsed from the error formatter's own `<status>: ` shape); success
statuses never cross the event surface, so no other record claims one.
The file sink writes the SAME `<iso8601> <message>` lines as the CLI
(`run start sid=…`, `tool start sid=… name=…`, `turn end sid=… stop=…`),
into the same `~/.fah/logs/fa.log` — one log for a host embed and a CLI
session, every line attributable via `sid=`.

Pure-Dart/web hosts get the interface plus `InMemoryTelemetrySink` (a
bounded ring) — no `dart:io` crosses the core boundary.

## Cancel, watchdogs, and what "hung" means now

- Every run carries a `CancelToken`; `agent.abort()` cancels it. Provider
  streams observe the token — the request stops consuming budget.
- The run-idle watchdog (8 min default) fires when NO event arrives
  outside tool execution: the turn ends `aborted`, `onRunIdleTimeout`
  fires, the host's busy row un-wedges. Legitimate silent windows are
  bounded below it (connect 180 s, stream-idle 300 s).
- Long tool calls get stuck-tool heartbeats when `AgentWiringSpec.stuckTool`
  is set; telemetry records them so a wedged call is attributable.

## Session service

Hosts that want durable sessions drive the same session repo the CLI does
(`SessionRepo` over your storage) — see `lib/src/session/` and the CLI's
`jsonlChildSessionOpener` for the reference wiring. The host decides where
session files live; the SDK never assumes a filesystem.
