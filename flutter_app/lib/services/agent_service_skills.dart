// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the per-skill availability members of
// [AgentService] live here (issue #1151) so the main file stays as close
// to the 2800-line guard as its pre-existing size allows. Same library,
// so private members resolve; the backing fields stay in the class body.

part of 'agent_service.dart';

/// Per-skill availability (issue #1151): the app twin of the CLI `skills:`
/// per-skill toggles over the package builtins.
extension AgentServiceSkills on AgentService {
  /// Whether the skill [name] is enabled — the per-skill toggles
  /// ([SkillsTogglesStore]) default every unmentioned skill ON.
  bool isSkillEnabled(String name) => _skillToggles[name] ?? true;

  /// Switches one skill's availability (the settings "Built-in skills"
  /// rows): persists the choice when a store is wired (fire-and-forget),
  /// then re-discovers skills under the new toggles and recomposes the
  /// system prompt — same shape as [AgentService.setSkillsAccess].
  /// Services built from a pre-constructed [Agent] (tests) have no config:
  /// they record the choice but skip the re-discovery.
  Future<void> setSkillToggle(String name, bool enabled) async {
    if (isSkillEnabled(name) == enabled) return;
    _skillToggles = {..._skillToggles, name: enabled};
    _skillTogglesGeneration++;
    _notify();
    final store = _skillTogglesStore;
    if (store != null) unawaited(store.save(_skillToggles));
    final config = _config;
    if (config == null) return;
    final generation = _skillTogglesGeneration;
    final suffix = await AgentService._discoverPromptSuffix(
      env,
      _skillsAccess,
      homeDir: _skillsHomeDir ?? desktopHomeDir(),
      skillToggles: _skillToggles,
    );
    // A newer toggle change made while discovery ran wins — don't clobber.
    if (generation != _skillTogglesGeneration) return;
    _promptSuffix = suffix;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
  }
}
