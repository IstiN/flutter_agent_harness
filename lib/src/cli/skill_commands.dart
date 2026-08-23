/// Skill invocation and management commands split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line file-size gate.
/// Same library (a `part of`), so the extension sees the class's private
/// members.
part of 'agent_cli.dart';

/// Implementation members of [AgentCli] for skills: third-party access
/// gating (the startup consent dialog and `/skills access`), `/skill:<name>`
/// invocation (rendering, per-turn tool grants, `context: fork`), and the
/// `/skills` management command.
extension AgentCliSkillsExt on AgentCli {
  /// Which skill/agent sources discovery may scan: everything once the user
  /// granted access, own roots (`.fah`, `.agents`) only otherwise.
  Set<SkillSource>? get _skillsAllowedSources =>
      _skillsAccess == SkillsAccess.granted
      ? null
      : const {SkillSource.fah, SkillSource.agents};

  /// Whether any third-party skill or agent root exists on disk. Only
  /// checked while access is not granted (drives the consent dialog and the
  /// "disabled" hint); listing a directory is metadata, not skill content.
  Future<bool> _detectThirdPartySkillDirs() async {
    if (_skillsAccess == SkillsAccess.granted) return false;
    final skillRoots = defaultSkillRoots(
      cwd: _env.cwd,
      homeDir: config.homeDir,
    );
    final agentRoots = defaultAgentRoots(
      cwd: _env.cwd,
      homeDir: config.homeDir,
    );
    for (final root in [...skillRoots.projectRoots, ...skillRoots.userRoots]) {
      if (!root.isThirdParty) continue;
      if ((await _env.listDir(root.path)).valueOrNull != null) return true;
    }
    for (final root in [...agentRoots.projectRoots, ...agentRoots.userRoots]) {
      if (!skillSourceIsThirdParty(root.source)) continue;
      if ((await _env.listDir(root.path)).valueOrNull != null) return true;
    }
    return false;
  }

  /// Re-runs skill discovery with the current access gate and recomposes the
  /// system prompt (`/skills reload`, consent changes, `/skills import`).
  Future<void> _reloadSkills() async {
    final roots = defaultSkillRoots(cwd: _env.cwd, homeDir: config.homeDir);
    _skills = await discoverSkills(
      _env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      allowedSources: _skillsAllowedSources,
    );
    _applyPromptComposition();
  }

  /// Re-runs agent-type discovery with the current access gate.
  Future<void> _reloadAgents() => discoverAgentsFromRoots(
    defaultAgentRoots(cwd: _env.cwd, homeDir: config.homeDir),
    allowedSources: _skillsAllowedSources,
  );

  /// Changes the third-party consent, persists it through the host callback,
  /// and re-discovers skills and agents under the new gate.
  Future<void> _setSkillsAccess(SkillsAccess access) async {
    _skillsAccess = access;
    config.onSkillsAccessChanged?.call(access);
    await _reloadSkills();
    await _reloadAgents();
    io.writeln(
      'skills access: ${skillsAccessLabel(access)} — '
      '${_skills.length} skill(s) visible',
    );
  }

  /// The consent options of the startup skills dialog.
  static const _skillsAccessOptions = <FlowOption>[
    (
      'granted',
      'Allow',
      'Fa reads .claude, .github and .codex skill/agent dirs (remembered)',
    ),
    ('ask', 'Not now', 'Keep them disabled; ask again next launch'),
    ('denied', 'Never', "Never read other tools' directories (remembered)"),
  ];

  static const _skillsAccessQuestion =
      'Found Claude/Copilot/Codex skills or agents in this project.';

  /// The one-time consent question for third-party skill/agent roots, asked
  /// at REPL start when the config has no decision yet and such roots exist.
  /// "Not now" (or Esc) keeps the undecided state so the next launch asks
  /// again; Allow/Never are persisted by the host.
  ///
  /// Line mode reads answers straight from [lineIterator] (the dispatch loop
  /// has not started yet, so the guided-flow `_promptLine` routing cannot
  /// work here); the TUI uses the regular wizard picker.
  Future<void> _maybePromptSkillsAccess({
    StreamIterator<String>? lineIterator,
  }) async {
    if (_skillsAccess != SkillsAccess.ask) return;
    if (!io.isInteractive || !_thirdPartySkillDirsPresent) return;
    String? choice;
    if (_useTui && _tuiController != null) {
      choice = await _pickOption(_skillsAccessQuestion, _skillsAccessOptions);
    } else if (lineIterator != null) {
      choice = await _promptSkillsAccessLine(lineIterator);
    } else {
      return;
    }
    if (choice == null || choice == 'ask') {
      io.writeln(
        _style.dim(
          'third-party skills stay disabled — change anytime via '
          '/skills access',
        ),
      );
      return;
    }
    await _setSkillsAccess(
      choice == 'granted' ? SkillsAccess.granted : SkillsAccess.denied,
    );
  }

  /// The line-mode branch of [_maybePromptSkillsAccess]: numbered options
  /// read directly from [lines] (same pattern as the `/` line-mode menu).
  /// EOF resolves to "Not now".
  Future<String?> _promptSkillsAccessLine(StreamIterator<String> lines) async {
    _printFlowOptions(_skillsAccessQuestion, _skillsAccessOptions, null);
    for (;;) {
      io.write('type a number (1-${_skillsAccessOptions.length}): ');
      if (!await lines.moveNext()) return null;
      final answer = lines.current.trim();
      final number = int.tryParse(answer);
      if (number != null &&
          number >= 1 &&
          number <= _skillsAccessOptions.length) {
        return _skillsAccessOptions[number - 1].$1;
      }
      if (answer.isEmpty) return null;
      io.writeln('invalid selection: $answer');
    }
  }

  /// `/skill:<name> [args]` and the `/<name>` alias: renders the skill body
  /// (argument substitution + shell injections), applies its per-turn tool
  /// grants, then runs it — inline as a user message, or forked into a
  /// subagent when the manifest says `context: fork`.
  Future<void> _runSkillCommand(String rest) async {
    final (name, args) = _parseSkillInvocation(rest);
    final skill = _skills
        .where((s) => s.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (skill == null) {
      io.writeln(
        'unknown skill: $name'
        '${_skills.isEmpty ? ' (no skills discovered)' : ''}',
      );
      return;
    }
    if (!skill.userInvocable) {
      io.writeln('skill ${skill.name} is model-only (user-invocable: false)');
      return;
    }
    io.writeln('skill ${skill.name} — ${skill.filePath}');
    final SkillRenderResult rendered;
    try {
      rendered = await renderSkillBody(
        _env,
        skill,
        args: args,
        sessionId: _session?.cachedId,
        projectDir: _env.cwd,
        shellExecutionEnabled: !config.skillsDisableShellExecution,
      );
    } on SkillRenderException catch (error) {
      io.writeln('skill ${skill.name}: $error');
      return;
    }
    for (final note in rendered.notes) {
      io.writeln(_style.dim('  ${skill.name}: $note'));
    }
    // Claude `allowed-tools`/`disallowed-tools` become per-turn approval
    // grants. Only plain tool names grant; `Bash(git:*)` patterns are
    // reported as discovery notes (see SkillManifest.notes).
    _approval.clearTurnGrants();
    _approval.grantForTurn(
      allow: skill.manifest.plainAllowedTools,
      deny: skill.manifest.disallowedTools,
    );
    if (skill.manifest.contextFork) {
      await _runForkedSkill(skill, rendered.body);
      return;
    }
    if (isBusy) {
      _agent.steer(UserMessage.text(rendered.body));
    } else {
      _startRun(rendered.body);
    }
  }

  /// `context: fork` skills run the rendered body as a subagent task instead
  /// of inline context (Claude Code semantics). `background: true` forks
  /// into a background job — its completion arrives through the normal
  /// task-completion steering; otherwise the result starts a fresh turn so
  /// the main agent can summarize it.
  Future<void> _runForkedSkill(Skill skill, String body) async {
    final tool = _toolRegistry.lookup(taskToolName);
    if (tool == null) {
      io.writeln(
        'skill ${skill.name}: context: fork requires the task tool '
        '(unavailable)',
      );
      return;
    }
    final agentName = canonicalTaskAgentName(
      skill.manifest.agent ?? defaultTaskAgentName,
    );
    try {
      final result = await tool.execute(
        {
          'context':
              'Skill "${skill.name}" (${skill.filePath}) invoked with '
              'context: fork.',
          'tasks': [
            {'name': skill.name, 'agent': agentName, 'task': body},
          ],
          'background': skill.manifest.background,
        },
        null,
        null,
      );
      await _applyForkResult(skill, result);
    } on Object catch (error) {
      io.writeln('skill ${skill.name}: fork failed: $error');
    }
  }

  /// Handles the result of a forked skill: background jobs just print a
  /// notice; foreground jobs start a new run with the subagent's text output.
  Future<void> _applyForkResult(Skill skill, ToolExecutionResult result) async {
    if (skill.manifest.background) {
      io.writeln(
        _style.dim(
          '  forked into a background subagent — its completion will '
          'arrive as a message',
        ),
      );
      return;
    }
    final text = [
      for (final block in result.content)
        if (block is TextContent) block.text,
    ].join('\n');
    _startRun(
      'The skill "${skill.name}" ran in a forked subagent. '
      'Its result:\n\n$text',
    );
  }

  /// Splits `/skill:<name> [args]` into the skill name and its args.
  (String, String) _parseSkillInvocation(String rest) {
    final splitAt = rest.indexOf(RegExp(r'\s'));
    final name = (splitAt < 0 ? rest : rest.substring(0, splitAt)).trim();
    final args = splitAt < 0 ? '' : rest.substring(splitAt).trim();
    return (name, args);
  }

  /// `/skills [reload|access [ask|granted|denied]|import]`.
  Future<void> _skillsSlash(String rest) async {
    final parts = rest
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    final sub = parts.isEmpty ? '' : parts.first;
    switch (sub) {
      case '':
        _listSkills();
      case 'reload':
        await _reloadSkills();
        await _reloadAgents();
        io.writeln(
          'reloaded: ${_skills.length} skill(s), '
          '${_discoveredAgents.length} discovered agent type(s)',
        );
      case 'access':
        await _skillsAccessSlash(parts.length > 1 ? parts[1] : '');
      case 'import':
        await _importThirdPartySkills();
      default:
        io.writeln(
          'unknown /skills subcommand: $sub (try reload, access, import)',
        );
    }
  }

  /// `/skills access [ask|granted|denied]`: prints or changes the
  /// third-party consent.
  Future<void> _skillsAccessSlash(String arg) async {
    if (arg.isEmpty) {
      io.writeln('skills access: ${skillsAccessLabel(_skillsAccess)}');
      io.writeln(
        _style.dim(
          '  granted — read Claude/Copilot/Codex skill & agent dirs; '
          'denied — never; ask — prompt at startup',
        ),
      );
      return;
    }
    final normalized = arg.trim().toLowerCase();
    if (normalized != 'ask' &&
        normalized != 'granted' &&
        normalized != 'denied') {
      io.writeln('unknown access level: $arg (ask|granted|denied)');
      return;
    }
    await _setSkillsAccess(skillsAccessFromLabel(normalized));
  }

  /// `/skills import`: copies the discovered third-party skills into
  /// `.fah/skills/` so they become owned (no consent gate, no format
  /// quirks). Only the SKILL.md file is copied — auxiliary skill files stay
  /// with the original directory.
  Future<void> _importThirdPartySkills() async {
    final thirdParty = _skills
        .where((s) => skillSourceIsThirdParty(s.source))
        .toList();
    if (thirdParty.isEmpty) {
      io.writeln(
        'nothing to import (no third-party skills discovered — '
        'see /skills access)',
      );
      return;
    }
    final ownNames = _skills
        .where((s) => !skillSourceIsThirdParty(s.source))
        .map((s) => s.name.toLowerCase())
        .toSet();
    var imported = 0;
    for (final skill in thirdParty) {
      if (ownNames.contains(skill.name.toLowerCase())) {
        io.writeln('  skip ${skill.name} — an own skill with that name exists');
        continue;
      }
      final text = (await _env.readTextFile(skill.filePath)).valueOrNull;
      if (text == null) {
        io.writeln('  skip ${skill.name} — cannot read ${skill.filePath}');
        continue;
      }
      final target = '${_env.cwd}/.fah/skills/${skill.name}/SKILL.md';
      final writeError = (await _env.writeFile(target, text)).errorOrNull;
      if (writeError != null) {
        io.writeln('  failed ${skill.name}: ${writeError.message}');
        continue;
      }
      imported++;
      io.writeln('  imported ${skill.name} → $target');
    }
    if (imported > 0) await _reloadSkills();
  }

  /// `/skills` — lists the discovered skills (name, description, location,
  /// source and invocation flags).
  void _listSkills() {
    if (_skills.isEmpty) {
      final extra = _skillsAccess == SkillsAccess.granted
          ? ', .claude/skills, .github/skills, .codex/skills'
          : ' — third-party roots disabled, see /skills access';
      io.writeln(
        'no skills discovered (roots: .fah/skills, .agents/skills$extra)',
      );
      return;
    }
    io.writeln('skills:');
    for (final skill in _skills) {
      final flags = [
        if (!skill.userInvocable) 'model-only',
        if (!skill.modelInvocable) 'user-only',
        if (skill.manifest.contextFork) 'fork',
        if (skill.manifest.paths.isNotEmpty) 'path-gated',
      ];
      io.writeln(
        '  ${skill.name} — ${skill.description}  '
        '${_style.dim('${skill.filePath} (${skill.scope.name}, ${skill.source.name}'
        '${flags.isEmpty ? '' : '; ${flags.join(', ')}'})')}',
      );
    }
  }
}
