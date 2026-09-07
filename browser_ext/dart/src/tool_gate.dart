// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';

import 'ui_protocol.dart';

/// Pure per-tool enable/disable over the host's tool sources (the panel
/// `tools_put` flow, issue #34). The gate owns the DESIRED state; the host
/// applies the diff to its live [ToolRegistry] and re-syncs the agent.
final class ToolGate {
  ToolGate(Map<String, AgentTool> sources) : _sources = sources {
    _enabled.addAll(sources.keys);
  }

  /// Every tool the host can offer, by name. Superset of [_enabled]:
  /// disabled tools stay here so a later `tools_put` can re-enable them.
  final Map<String, AgentTool> _sources;
  final _enabled = <String>{};

  /// Names currently enabled.
  Set<String> get enabled => Set.unmodifiable(_enabled);

  /// The wire snapshot (`tools_state`).
  List<UiToolState> snapshot() => [
        for (final name in _sources.keys)
          UiToolState(name: name, enabled: _enabled.contains(name)),
      ];

  /// Applies a `tools_put` payload. Unknown names are ignored (the panel
  /// may lag a tool the SW no longer has). Returns true when the desired
  /// state changed — the caller then re-syncs its registry.
  bool apply(List<UiToolState> put) {
    var changed = false;
    for (final state in put) {
      if (!_sources.containsKey(state.name)) continue;
      if (state.enabled == _enabled.contains(state.name)) continue;
      changed = true;
      if (state.enabled) {
        _enabled.add(state.name);
      } else {
        _enabled.remove(state.name);
      }
    }
    return changed;
  }

  /// Registers every enabled source into [registry] and unregisters the
  /// disabled ones (idempotent; the registry tolerates re-registration).
  void sync(ToolRegistry registry) {
    for (final entry in _sources.entries) {
      final active = _enabled.contains(entry.key);
      final present = registry.names.contains(entry.key);
      if (active && !present) registry.register(entry.value);
      if (!active && present) registry.unregister(entry.key);
    }
  }
}
