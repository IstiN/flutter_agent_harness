// Prompt composition for the terminal CLI core (part of agent_cli.dart,
// extracted under the issue #679 line cap): the system-prompt assembly
// from the active mode's base prompt (or the explicit override) plus the
// project-context and skills sections (pi/kimi-style: appended after the
// base prompt). Per-instance fields stay on [AgentCli] — extensions
// cannot add fields.
part of 'agent_cli.dart';

extension AgentCliPromptComposition on AgentCli {
  /// Whether the pi benchmark mode is active for this session (issue
  /// #679): the executable resolves flag > env > config (AC3) and passes
  /// the result via [AgentCliConfig.agentMode].
  bool get _piActive => config.agentMode == 'pi';

  /// Rebuilds the agent's system prompt from the active mode (or the
  /// explicit override) plus the project-context and skills sections
  /// (pi/kimi-style: appended after the base prompt).
  void _applyPromptComposition() {
    if (_piActive) {
      // pi mode (issue #679): the bare benchmark profile — the generated
      // `mode_pi` template (identity, 4 tool docs, safety rules) plus the
      // project-context section (AGENTS.md — pi loads it, parity). NO
      // skills, memory, messaging, MCP, or ext sections. Late-arriving
      // MCP tool docs are stripped by the pi override in
      // refilterMcpTools, so recomposing here stays bare.
      _agent.state.systemPrompt = _mcp.composePrompt(
        config.systemPrompt ?? cliPiModePrompt,
        contextSection: formatProjectContext(_contextFiles),
        skillsSection: '',
      );
      return;
    }
    _agent.state.systemPrompt = _mcp.composePrompt(
      config.systemPrompt ?? _currentMode.systemPrompt,
      contextSection: formatProjectContext(_contextFiles),
      skillsSection: formatSkillsForPrompt(
        _skills,
        touchedPaths: _touchedPaths,
        cwd: _env.cwd,
      ),
      memorySection: _memorySection,
      messagingSection: _messagingSection(),
      extSection: _ext.promptSection,
    );
  }

  /// The `## Agent messaging` prompt section: the agent's own mailbox in
  /// the fabric + how discovery/addressing work. Empty until the session
  /// (and thus the mailbox prefix) exists.
  String _messagingSection() {
    final prefix = _subagentManager.mailboxPrefix;
    if (_subagentManager.messaging == null || prefix.isEmpty) return '';
    return cliMessagingSectionPrompt.replaceAll(
      '{{mailbox}}',
      _subagentManager.mailboxOf(_subagentManager.selfId),
    );
  }

  /// The runtime `memory:` section (project `.fah/config.yaml` wins over
  /// the user-level one — the same merge as boot). Re-read on every
  /// memory operation by the controller's configSource; a broken file
  /// keeps the last good config (the controller swallows source errors).
  MemoryConfig? _liveMemoryConfig() {
    final project = loadProjectMemoryConfig(_env.cwd);
    if (project != null) return project;
    final home = config.homeDir;
    return home == null ? null : loadCliConfig(home).memory;
  }

  /// Re-reads the `<memory>` section from the memory stores and recomposes
  /// the prompt when it changed.
  Future<void> _refreshMemorySection() async {
    final section = await _memory.formatPromptSection();
    if (section == _memorySection) return;
    _memorySection = section;
    _applyPromptComposition();
  }
}
