/// The flutter_app shell's capability profile (issue #1079, slice 5 — the
/// app host adopts the shared builder).
///
/// The seven built-in profiles pin the issue matrix's TARGET states. The
/// flutter_app is one shell spanning macOS/iOS/Android/web, and its
/// builder-level wiring today is platform-uniform: the per-platform
/// differences live in the shell's own tool construction (the calendar /
/// contacts / health / home / mobile bridges) and in the on-device
/// provider choice, not in the capability gating. This profile declares
/// that honest TODAY-state — the narrowing invariant runs per boot anyway
/// (`wireAgentCore` run-narrows against the services the shell actually
/// provides), and per-platform splits land when the platform differences
/// reach the capability level (the mobile MCP / WASI-sandbox cards).
///
/// Nothing the app wires today is taken away (the epic's non-goal): every
/// capability the shell exercises is `on` here, and the off cells name
/// the card that raises them.
///
/// Pure Dart: no `dart:io`.
library;

import 'host_capability_profile.dart';

/// The app host's profile: what the flutter_app shell wires through
/// [HostWiringBuilder] today, per capability, with the honest reason on
/// every `off` cell.
///
/// Key cells (the full table is the [states] map — E2-complete by
/// construction):
///
/// - `messaging_fabric: transport({file, hub})` — the file inboxes live
///   next to the sessions in the platform sandbox (or origin storage on
///   web); the hub is the opt-in agent network (issue #402), swapped in
///   by the shell's network controller over the builder's file fabric.
/// - `sandbox_env: off` — the platform env (desktop container, mobile
///   sandbox, browser store) IS the app's sandbox; no cube layer yet.
/// - `on_device_providers: on` — webllm / gemma / transformers.js are the
///   app's in-process backends.
/// - `js_apps: on` — dynamic_message and the jsr app surface are core
///   app features (the matrix's browser-API row).
/// - `mcp` / `sqlite_lsp_dap` / `checkpoint_rewind` / `browser_bridge` /
///   `vision_transcribe` / `js_extensions: off(reason)` — the app's
///   registry floor (issue #692): process/transport-backed surfaces stay
///   absent; the app's own media family rides the shell extension until
///   the config-slot media card lands.
final HostCapabilityProfile flutterAppHostProfile = HostCapabilityProfile(
  name: 'flutter-app',
  states: {
    HostCapability.configSections: CapabilityState.on,
    HostCapability.compaction: CapabilityState.on,
    HostCapability.loadModes: CapabilityState.on,
    HostCapability.mcp: CapabilityState.off(
      'the app host wires no MCP manager yet; remote MCP lands with the '
      'mobile MCP card',
    ),
    HostCapability.messagingFabric: CapabilityState.transport(
      {'file', 'hub'},
      'file inboxes live in the platform sandbox next to the sessions; '
      'hub is the opt-in agent network (issue #402)',
    ),
    HostCapability.approvalGate: CapabilityState.on,
    HostCapability.skills: CapabilityState.on,
    HostCapability.sandboxEnv: CapabilityState.off(
      'the platform env is the app sandbox (desktop container, mobile '
      'sandbox, browser store); no cube layer yet',
    ),
    HostCapability.backgroundShellJobs: CapabilityState.on,
    HostCapability.sqliteLspDap: CapabilityState.off(
      'no FFI/sql.js engine and no lsp/dap transports are wired in the '
      'app host yet',
    ),
    HostCapability.onDeviceProviders: CapabilityState.on,
    HostCapability.jsApps: CapabilityState.on,
    HostCapability.checkpointRewind: CapabilityState.off(
      'the app host has no checkpoint/rewind surface yet',
    ),
    HostCapability.hostExtensionApi: CapabilityState.on,
    HostCapability.webSearch: CapabilityState.on,
    HostCapability.visionTranscribe: CapabilityState.off(
      "the app's media family rides its MediaGateway shell extension; "
      'config-slot inspect/transcribe arrive with the media card',
    ),
    HostCapability.subagents: CapabilityState.on,
    HostCapability.browserBridge: CapabilityState.off(
      'no browser automation bridge in the app host yet',
    ),
    HostCapability.jsExtensions: CapabilityState.off(
      'the QuickJS extension host is a CLI process surface; the app uses '
      'the js_apps browser-API surface',
    ),
  },
);
