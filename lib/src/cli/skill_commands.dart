/// Skill invocation and management commands split from [AgentCli] to keep
/// agent_cli.dart under the repo's 2800-line file-size gate.
/// Same library (a `part of`), so the extension sees the class's private
/// members.
part of 'agent_cli.dart';

/// The merge inputs read from the existing project file: the current
/// toggles, the raw `skills:` node (null when absent — needed to
/// re-emit the section keys), and the error that blocks the merge
/// (the other fields are inert when [error] is set).
typedef _MergeSeed = ({SkillsConfig config, YamlMap? section, String? error});

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

  /// Prints why third-party skills are missing, when the consent dialog
  /// cannot or will not appear: non-interactive runs, and interactive runs
  /// whose access is already denied. In line mode this prints right after
  /// discovery; in TUI mode `_runTuiRepl` re-prints it after the banner —
  /// the alternate screen would wipe the original line.
  void _printThirdPartySkillsDisabledHint() {
    if (!_thirdPartySkillDirsPresent) return;
    if (_skillsAccess == SkillsAccess.granted) return;
    if (io.isInteractive && _skillsAccess == SkillsAccess.ask) return;
    io.writeln(
      _style.dim(
        'Claude/Copilot/Codex skills or agents found but disabled — '
        '/skills access granted to enable',
      ),
    );
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
      builtins: builtinSkills(),
    );
    await _resolveSkillAvailability();
    // gh-1409: republish the operative-pin source set — the agent's next
    // request rebuilds the pin registry from THIS list (derived state, P2).
    _agent.operativeSkills = List.of(_enabledSkills);
    _applyPromptComposition();
  }

  /// Resolves the `skills:` toggle scopes (issue #1151 — global
  /// [AgentCliConfig.skillToggles] < project `.fah/config.yaml`) against
  /// [_skills], warns about unknown toggle ids once per distinct name,
  /// and recomputes [_enabledSkills] + [_skillResolution]. A broken
  /// project section is data, not an exception: the error prints and the
  /// last good project toggles stay in effect (the tools twin,
  /// `readToolsScopeFile`, works the same way).
  Future<void> _resolveSkillAvailability() async {
    if (!_globalSkillTogglesLoaded) {
      _globalSkillToggles = Map.of(config.skillToggles);
      _globalSkillTogglesLoaded = true;
    }
    final project = await _readProjectSkillToggles();
    final resolution = resolveSkillAvailability(
      skills: _skills,
      scopes: [
        (SkillToggleScope.global, SkillsConfig(skills: _globalSkillToggles)),
        if (project != null)
          (SkillToggleScope.project, SkillsConfig(skills: project)),
      ],
    );
    final fresh = resolution.unknownIds.difference(_warnedSkillToggleIds);
    for (final id in fresh) {
      io.writeln(
        _style.dim(
          'skills: toggle "$id" ignored — no discovered skill has that name',
        ),
      );
    }
    if (fresh.isNotEmpty) {
      _warnedSkillToggleIds = {..._warnedSkillToggleIds, ...fresh};
    }
    _skillResolution = resolution;
    _enabledSkills = enabledSkills(_skills, resolution);
  }

  /// Re-runs agent-type discovery with the current access gate.
  Future<void> _reloadAgents() => discoverAgentsFromRoots(
    defaultAgentRoots(cwd: _env.cwd, homeDir: config.homeDir),
    allowedSources: _skillsAllowedSources,
  );

  /// The project `skills:` toggles, read through the [ExecutionEnv] —
  /// scopes travel with the env, mirroring the tools wiring (web-safe,
  /// and visible to the MemoryExecutionEnv test harness). Null when the
  /// file or the section is absent; a present-but-invalid section is
  /// reported and the LAST GOOD toggles stay in effect — one broken
  /// project file must never kill `/skills`, the REPL loop, or boot
  /// (issue #1151 review; the tools twin is `readToolsScopeFile`).
  Future<Map<String, bool>?> _readProjectSkillToggles() async {
    final (read, error) = await _readProjectSkillTogglesFile();
    if (error != null) {
      io.writeln('skills: $error — project scope ignored, keeping last good');
      return _lastGoodProjectSkillToggles;
    }
    if (read != null) _lastGoodProjectSkillToggles = read;
    return read;
  }

  /// The strict parse behind [_readProjectSkillToggles]: returns
  /// `(null, null)` when the file or the section is absent, `(null,
  /// message)` when the file/section is broken, else the parsed toggles.
  Future<(Map<String, bool>?, String?)> _readProjectSkillTogglesFile() async {
    final path = '${_env.cwd}/.fah/config.yaml';
    final source = (await _env.readTextFile(path)).valueOrNull;
    if (source == null || source.trim().isEmpty) return (null, null);
    final Object? doc;
    try {
      doc = loadYaml(source);
    } on Object catch (error) {
      return (null, 'cannot parse $path: $error');
    }
    if (doc is! YamlMap) return (null, 'cannot parse $path: not a yaml map');
    final node = doc['skills'];
    if (node == null) return (null, null);
    try {
      return (SkillsConfig.fromYaml(node).skills, null);
    } on ConfigException catch (error) {
      return (null, 'invalid skills section in $path: ${error.message}');
    }
  }

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
    final skill = _enabledSkills
        .where((s) => s.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (skill == null) {
      // Discovered but toggled off: name the way back instead of a bare
      // "unknown skill" (the toggle scopes, issue #1151).
      final disabled = _skills
          .where((s) => s.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (disabled != null) {
        final scope = _skillResolution.byName[disabled.name]?.scope?.name;
        io.writeln(
          'skill ${disabled.name} is disabled${scope == null ? '' : ' ($scope)'}'
          ' — enable with /skills on ${disabled.name}',
        );
        return;
      }
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

  /// `/skills [reload|access [ask|granted|denied]|import|on|off <name> [global|project]]`.
  ///
  /// Dispatch only — each branch body lives in its own CC≤2 helper so every
  /// piece stays under the CRAP ratchet even where only the line-mode paths
  /// are test-covered.
  Future<void> _skillsSlash(String rest) async {
    final (:sub, :args) = splitSlashArgs(rest);
    switch (sub) {
      case '':
        await _skillsListOrMenu();
      case 'reload':
        await _skillsReloadSlash();
      case 'access':
        await _skillsAccessEntry(args);
      case 'import':
        await _importThirdPartySkills();
      case 'on' || 'off':
        await _skillsToggleSlash(sub == 'on', args);
      default:
        io.writeln(
          'unknown /skills subcommand: $sub '
          '(try reload, access, import, on, off)',
        );
    }
  }

  /// The bare `/skills` branch: the plain text list (line mode manages via
  /// `/skills access`; a TUI management menu is a follow-up).
  Future<void> _skillsListOrMenu() async {
    _listSkills();
  }

  /// The `/skills reload` branch: re-scan skills + agent types and report.
  Future<void> _skillsReloadSlash() async {
    await _reloadSkills();
    await _reloadAgents();
    io.writeln(
      'reloaded: ${_skills.length} skill(s), '
      '${_discoveredAgents.length} discovered agent type(s)',
    );
  }

  /// The `/skills access` entry: a bare interactive line-mode invocation
  /// runs DETACHED — the sequential REPL loop awaits each command, so an
  /// awaited line-prompted flow would deadlock on its own answer (guided
  /// provider flows use the same pattern; answers arrive through
  /// `_pendingPromptAnswer` from the loop's next reads).
  Future<void> _skillsAccessEntry(List<String> args) async {
    final bareInteractiveLine =
        args.isEmpty &&
        io.isInteractive &&
        !(_useTui && _tuiController != null);
    if (bareInteractiveLine) {
      unawaited(_openSkillsAccessPicker());
      return;
    }
    await _skillsAccessSlash(args.isEmpty ? '' : args.first);
  }

  /// `/skills access [ask|granted|denied]`: bare opens the interactive
  /// picker; a level label changes the consent directly.
  Future<void> _skillsAccessSlash(String arg) async {
    if (arg.isEmpty) {
      // Headless/piped input cannot answer an interactive picker — print
      // the current consent and the way to change it instead.
      if (!io.isInteractive) {
        io.writeln('skills access: ${skillsAccessLabel(_skillsAccess)}');
        io.writeln(
          _style.dim('  change with /skills access ask|granted|denied'),
        );
        return;
      }
      await _openSkillsAccessPicker();
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

  /// The bare `/skills access` picker: the three consent levels with the
  /// current one marked, through the shared guided-flow option picker (TUI
  /// picker or a numbered line-mode list).
  Future<void> _openSkillsAccessPicker() async {
    const title = 'Third-party skills access';
    const options = <FlowOption>[
      ('ask', 'Ask', 'Prompt at startup when third-party roots are found'),
      ('granted', 'Granted', 'Read Claude/Copilot/Codex skill and agent dirs'),
      ('denied', 'Disabled', "Never read other tools' directories"),
    ];
    final choice = await _pickOption(
      title,
      options,
      initialKey: skillsAccessLabel(_skillsAccess),
    );
    if (choice == null) return;
    final access = skillsAccessFromLabel(choice);
    if (access == _skillsAccess) return;
    await _setSkillsAccess(access);
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
  ///
  /// The description column runs through [_skillListDetail].
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
      final decision = _skillResolution.byName[skill.name];
      // Display text: a builtin's model-facing description runs hundreds
      // of chars and would wrap one row over a screenful at 80 columns -
      // cap it so one skill stays one terminal line (issue #1151; the
      // system-prompt block keeps the full text).
      final detail = _skillListDetail(skill.description);
      final flags = [
        if (!skill.userInvocable) 'model-only',
        if (!skill.modelInvocable) 'user-only',
        if (skill.manifest.contextFork) 'fork',
        if (skill.manifest.paths.isNotEmpty) 'path-gated',
        // The toggle state rides the dim tail (`; off (project)`) so the
        // line format stays one line per skill (issue #1151).
        if (decision != null && !decision.enabled)
          'off (${decision.scope?.name ?? 'default'})',
      ];
      io.writeln(
        '  ${skill.name} — $detail  '
        '${_style.dim('${skill.filePath} (${skill.scope.name}, ${skill.source.name}'
        '${flags.isEmpty ? '' : '; ${flags.join(', ')}'})')}',
      );
    }
    // A built-in hidden under a same-named project/user/granted skill gets
    // a shadow note: its absence from the invocation surface is a
    // precedence decision, not a bug (issue #1151).
    for (final builtin in builtinSkills()) {
      final winner = _skills
          .where((s) => s.name.toLowerCase() == builtin.name.toLowerCase())
          .firstOrNull;
      if (winner == null || winner.source == SkillSource.builtin) continue;
      io.writeln(
        _style.dim(
          '  ${builtin.name}: builtin skill shadowed by '
          '${winner.scope.name} skill',
        ),
      );
    }
    // A non-empty own-skills list still explains missing third-party skills
    // and shows the way out.
    if (_skillsAccess != SkillsAccess.granted && _thirdPartySkillDirsPresent) {
      io.writeln(
        _style.dim(
          'Claude/Copilot/Codex skills are disabled — '
          'enable via /skills access granted',
        ),
      );
    }
  }

  /// `/skills on|off <name> [global|project]` — the per-skill toggle arm,
  /// mirroring `/tools enable|disable <id> [scope]` (issue #1151). Defaults
  /// to the project scope; the settings-hub Skills flow routes here.
  Future<void> _skillsToggleSlash(bool enable, List<String> args) async {
    if (args.isEmpty) {
      io.writeln(
        'usage: /skills ${enable ? 'on' : 'off'} <name> [global|project]',
      );
      return;
    }
    await _applySkillToggle(
      enable,
      args.first,
      args.length > 1 ? args[1] : 'project',
    );
  }

  /// Persists the toggle to [scope] (`global|project`), then re-resolves
  /// availability and recomposes the prompt — same-session effect, no
  /// restart. A failed/unwritable target leaves the live state untouched.
  Future<void> _applySkillToggle(bool enable, String name, String scope) async {
    final skill = _skills
        .where((s) => s.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    if (skill == null) {
      io.writeln('unknown skill: $name (see /skills)');
      return;
    }
    final persisted = switch (scope) {
      'project' => await _mergeSkillsIntoFile(
        '${_env.cwd}/.fah/config.yaml',
        skill.name,
        enable,
      ),
      'global' => await _persistGlobalSkillToggle(skill.name, enable),
      _ => null,
    };
    if (persisted == null) {
      io.writeln('unknown scope: $scope (try global, project)');
      return;
    }
    if (!persisted) return;
    await _resolveSkillAvailability();
    _applyPromptComposition();
    io.writeln(
      'skills: ${enable ? 'enabled' : 'disabled'} ${skill.name} '
      '(scope: $scope)',
    );
  }

  /// The global scope is host-owned: the CLI updates its live toggles and
  /// the executable persists them through `onSkillTogglesChanged`.
  Future<bool> _persistGlobalSkillToggle(String name, bool enabled) async {
    _globalSkillToggles = {..._globalSkillToggles, name: enabled};
    _globalSkillTogglesLoaded = true;
    final hook = config.onSkillTogglesChanged;
    if (hook == null) {
      io.writeln(
        'skills: no persistence hook — global change kept for this session',
      );
      return true;
    }
    await hook();
    return true;
  }

  /// The live global per-skill toggles for the host's persistence; null
  /// before the first availability resolution, in which case the host
  /// keeps the loaded `skills:` section as-is.
  Map<String, bool>? get globalSkillToggles =>
      _globalSkillTogglesLoaded ? _globalSkillToggles : null;

  /// Parses the existing project file body for a toggle merge. Pure —
  /// no env — so the error branches are unit-testable as a table.
  _MergeSeed _mergeSeed(String path, String? source) {
    if (source == null || source.trim().isEmpty) {
      return (config: const SkillsConfig.empty(), section: null, error: null);
    }
    final Object? doc;
    try {
      doc = loadYaml(source);
    } on Object catch (error) {
      return (
        config: const SkillsConfig.empty(),
        section: null,
        error: '$error',
      );
    }
    if (doc is! YamlMap) {
      return (
        config: const SkillsConfig.empty(),
        section: null,
        error: '$path is not a map',
      );
    }
    final section = doc['skills'];
    if (section == null) {
      return (config: const SkillsConfig.empty(), section: null, error: null);
    }
    if (section is! YamlMap) {
      return (
        config: const SkillsConfig.empty(),
        section: null,
        error: 'skills must be a map in $path',
      );
    }
    try {
      return (
        config: SkillsConfig.fromYaml(section),
        section: section,
        error: null,
      );
    } on ConfigException catch (error) {
      // A syntactically valid file with an invalid section (e.g. a
      // non-boolean value) is data, not a crash — same contract as
      // the tools twin and the read path (issue #1151 review CQIw).
      return (
        config: const SkillsConfig.empty(),
        section: null,
        error: error.message,
      );
    }
  }

  /// Rebuilds the file body with `name: enabled` merged into the
  /// `skills:` block. [seed] carries the parsed section, [source] the
  /// original bytes (null/blank → a fresh file).
  String _mergedSkillsBody(
    _MergeSeed seed,
    String? source,
    String name,
    bool enabled,
  ) {
    final buffer = StringBuffer('skills:\n');
    final section = seed.section;
    if (section != null) {
      // The section parser only accepts these spellings, so re-emitting
      // the parsed values keeps the file valid.
      if (section['access'] != null) {
        buffer.write('  access: ${section['access']}\n');
      }
      if (section['disableShellExecution'] != null) {
        buffer.write(
          '  disableShellExecution: ${section['disableShellExecution']}\n',
        );
      }
    }
    buffer.write(
      SkillsConfig(skills: {...seed.config.skills, name: enabled}).toYaml(),
    );
    final body = (source == null || source.trim().isEmpty)
        ? buffer.toString()
        : _replaceTopLevelYamlBlock(source, 'skills', buffer.toString());
    return '$body\n';
  }

  /// Merges `name: enabled` into the `skills:` section of the yaml file at
  /// [path] (surgical top-level block rewrite; everything outside the
  /// block survives byte-for-byte). Inside the block the section's
  /// `access:`/`disableShellExecution:` keys are preserved — they are
  /// valid section keys the toggles parser [SkillsConfig] deliberately
  /// skips, and a toYaml-only rebuild would drop them. A file the merge
  /// cannot parse (broken yaml, non-map doc, invalid section) is data,
  /// not a crash: the error prints and nothing is written.
  Future<bool> _mergeSkillsIntoFile(
    String path,
    String name,
    bool enabled,
  ) async {
    final source = (await _env.readTextFile(path)).valueOrNull;
    final seed = _mergeSeed(path, source);
    if (seed.error != null) {
      io.writeln('skills: cannot merge project scope — ${seed.error}');
      return false;
    }
    if (await _env.writeFile(
          path,
          _mergedSkillsBody(seed, source, name, enabled),
        )
        is Err) {
      io.writeln('skills: could not write $path');
      return false;
    }
    return true;
  }

  /// The settings-hub Skills row and `/settings` summary label: the live
  /// on/off balance.
  String _skillsStatusLabel() =>
      '${_enabledSkills.length} of ${_skills.length} skills available';

  String _skillsEntryDetail(Skill skill) {
    final decision = _skillResolution.byName[skill.name];
    if (decision == null) return 'on (default)';
    final where = decision.scope?.name ?? 'default';
    return decision.enabled ? 'on ($where)' : 'off ($where)';
  }

  /// The settings-hub Skills flow: pick a skill, flip it, pick the scope
  /// to persist in — loops until cancelled. Mirrors the Tools flow.
  Future<void> _skillsSettingsFlow() async {
    for (;;) {
      final pick = await _pickSkillToggle();
      if (pick == null) return;
      await _applySkillToggle(pick.enable, pick.name, pick.scope);
    }
  }

  /// One Skills-flow pass: skill → on/off → scope. Null when the user
  /// cancels any step (or picks Done at the skill list).
  Future<({String name, bool enable, String scope})?> _pickSkillToggle() async {
    final name = await _pickSkillName();
    if (name == null) return null;
    final enable = await _pickSkillEnable(name);
    if (enable == null) return null;
    final scope = await _pickSkillScope(name, enable);
    if (scope == null) return null;
    return (name: name, enable: enable, scope: scope);
  }

  /// The skill pick; `Done` and a cancel both resolve to null.
  Future<String?> _pickSkillName() async {
    final name = await _pickOption('skills — pick a skill', [
      for (final skill in _skills)
        (skill.name, skill.name, _skillsEntryDetail(skill)),
      ('done', 'Done', ''),
    ]);
    return name == 'done' ? null : name;
  }

  /// The Skills flow's enable/disable picker rows.
  static const _skillActionOptions = <FlowOption>[
    ('on', 'Enable', 'offer the skill to the model again'),
    ('off', 'Disable', 'hide it from invocation, completion and prompt'),
  ];

  /// The enable/disable pick for [name]; null on cancel.
  Future<bool?> _pickSkillEnable(String name) async {
    final action = await _pickOption('skills — $name', _skillActionOptions);
    return switch (action) {
      'on' => true,
      'off' => false,
      _ => null,
    };
  }

  /// The scope pick for toggling [name], worded by the chosen action.
  Future<String?> _pickSkillScope(String name, bool enable) =>
      _pickOption('skills — ${enable ? 'enable' : 'disable'} $name in', [
        ('project', 'Project', '${_env.cwd}/.fah/config.yaml'),
        ('global', 'Global', '~/.fah/config.yaml'),
      ]);
}

/// The `/skills` description column: capped so a row's visible part stays
/// inside one ~80-col terminal line - a builtin's model-facing description
/// runs hundreds of chars and wrapped greet off the #927 consent suite's
/// 80x24 screen. The system-prompt block and the TUI completion overlay
/// keep the full text.
String _skillListDetail(String description) {
  const cap = 57;
  if (description.length <= cap) return description;
  return '${description.substring(0, cap)}…';
}
