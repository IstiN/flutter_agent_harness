---
id: "n_0997_fcdf"
type: "note"
title: "flutter_agent_harness gh-1572 rework contract (pr-1587): `AgentCliConfig.onUserConfigFileChanged` (wired in bin/fah_runapp.dart to `saved = loadCliConfig(home)`, ConfigException-guarded) fires after EVERY sanctioned direct write to the USER ~/.fah/config.yaml — `_upsertConfigYaml` (user-scope wins), `_clearContextCap`, `_dropAutoUpdateKey`, `_removeCapabilityYaml`, `_writeTtsrSection`, `_writeMcpSection` (fire helper `_notifyUserConfigFileChanged` in settings_flow_config_sync.dart — the roster in its doc is the exhaustive writer list). persistConfig's base is the mutable boot `saved`, so any NEW settings flow that writes the user config directly MUST fire the hook or the next persist resurrects the pre-write values. Project-scope writes don't fire it (snapshot tracks the user file only). `validateAgentSection` (config_service.dart) must know every key the `agent:` emitter renders (contextWindowCap/mode/misuseBreaker/stuckTool — per-key checks live in the `_agentKeyValidators` table, the switch form hit CRAP 13.02 over the 12.0 ratchet — pinned by the \"everything the emitter renders passes the strict mirror validator\" test); `_diskPreservedSections` must list every top-level key with no typed renderer (providersQueue was the last gap). Context-cap flow now lives in settings_flow_context_cap.dart (clear = key-only removeYamlPath, not the whole block)."
author: "agent"
date: "2026-10-13T20:59:05.702670Z"
area: "project"
topics: []
source: "agent"
accessCount: 0
importance: 0.5
tags: ["#note", "#source_agent", "false", "false"]
---


# Note: n_0997_fcdf

flutter_agent_harness gh-1572 rework contract (pr-1587): `AgentCliConfig.onUserConfigFileChanged` (wired in bin/fah_runapp.dart to `saved = loadCliConfig(home)`, ConfigException-guarded) fires after EVERY sanctioned direct write to the USER ~/.fah/config.yaml — `_upsertConfigYaml` (user-scope wins), `_clearContextCap`, `_dropAutoUpdateKey`, `_removeCapabilityYaml`, `_writeTtsrSection`, `_writeMcpSection` (fire helper `_notifyUserConfigFileChanged` in settings_flow_config_sync.dart — the roster in its doc is the exhaustive writer list). persistConfig's base is the mutable boot `saved`, so any NEW settings flow that writes the user config directly MUST fire the hook or the next persist resurrects the pre-write values. Project-scope writes don't fire it (snapshot tracks the user file only). `validateAgentSection` (config_service.dart) must know every key the `agent:` emitter renders (contextWindowCap/mode/misuseBreaker/stuckTool — per-key checks live in the `_agentKeyValidators` table, the switch form hit CRAP 13.02 over the 12.0 ratchet — pinned by the "everything the emitter renders passes the strict mirror validator" test); `_diskPreservedSections` must list every top-level key with no typed renderer (providersQueue was the last gap). Context-cap flow now lives in settings_flow_context_cap.dart (clear = key-only removeYamlPath, not the whole block).

**By:** [[agent]]
**Date:** 2026-10-13T20:59:05.702670Z
**Area:** [[project|project]]
