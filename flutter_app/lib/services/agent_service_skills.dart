// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the per-skill availability members of
// [AgentService] live here (issue #1151) so the main file stays as close
// to the 2800-line guard as its pre-existing size allows. Same library,
// so private members resolve; the backing fields stay in the class body.

part of 'agent_service.dart';

/// Writes the bundled app-only agent skill (`assets/skills/js-apps/`)
/// into the env's project skill root so [discoverSkills] picks it up.
/// The file is refreshed when the bundled content changed (the skill is
/// ours, not user data). Best-effort: a missing asset or unwritable env
/// must not block session creation.
///
/// Issue #1151 review (CQE1): copies the pre-#1151 seeder wrote for
/// skills that since moved INTO the package (`create-goal`) or retired
/// (`fa-self-config`) are retired with the same ownership rule — the old
/// seeder force-refreshed these files on every launch, so they are ours,
/// not user data. The cleanup is fingerprint-scoped: a copy is removed
/// ONLY when its SKILL.md is byte-identical to the last seeded bytes
/// (neither source carries `fa-platforms` markers or `{{FA_PLATFORM}}`,
/// so the seeder wrote these bytes verbatim on every platform). Only
/// SKILL.md goes — the seeder never wrote anything else into those
/// dirs, so a user-dropped supporting file (script, prompt) survives
/// (review -HUjo); an empty leftover dir is invisible to discovery.
/// Anything else is a deliberate project override and stays — a
/// customized create-goal keeps shadowing the builtin (issue non-goal:
/// migrating existing overrides), an orphaned fa-self-config stops
/// haunting every session prompt.
const _staleSeedFingerprints = <String, String>{
  'create-goal':
      '427d831fa7c41b44a225f216a6e1961bf54b2821a538971e972dcee2c9383f72',
  'fa-self-config':
      '88c3301a46f5298255dc3f0e3f2b65bca3c5c97ade17e616ce5ad257c28f8dea',
};

Future<void> _seedBundledSkills(ExecutionEnv env) async {
  for (final entry in _staleSeedFingerprints.entries) {
    try {
      final body = (await env.readTextFile(
        '${env.cwd}/.fah/skills/${entry.key}/SKILL.md',
      )).valueOrNull;
      if (body == null) continue;
      if (sha256.convert(utf8.encode(body)).toString() != entry.value) {
        continue;
      }
      await env.remove('${env.cwd}/.fah/skills/${entry.key}/SKILL.md');
    } on Object {
      // best-effort cleanup
    }
  }
  const bundled = {'js-apps': 'assets/skills/js-apps/SKILL.md'};
  for (final entry in bundled.entries) {
    try {
      final target = '.fah/skills/${entry.key}/SKILL.md';
      final bundledBody = await rootBundle.loadString(entry.value);
      final body = filterPlatformInstructions(
        bundledBody,
        platform: currentFaPlatform,
      );
      final existing = await env.readTextFile(target);
      if (existing.valueOrNull == body) continue;
      await env.writeFile(target, body);
    } on Object {
      // skip this skill
    }
  }
}

/// Discovers agent skills + project context files (AGENTS.md & friends)
/// and renders the system-prompt suffix. Third-party skill roots
/// (`.claude`, `.github/skills`, `.codex`) are read unless [access] is
/// [SkillsAccess.denied] (or an explicit `ask` still awaiting its startup
/// prompt) — discovery is on by default; only those restrict discovery to
/// the first-party roots (`.fah/skills`, `.agents/skills`).
///
/// The package builtins (`create-goal`, `self-settings`, issue #1151)
/// merge LAST — every on-disk skill of the same name shadows them — and
/// [skillToggles] (the app store's `skills:`-shaped wishes; the single
/// app-side scope, project config.yaml toggles are NOT read here) filter
/// the discovered list down to the enabled skills.
Future<String> _discoverPromptSuffix(
  ExecutionEnv env,
  SkillsAccess access, {
  String? homeDir,
  Map<String, bool> skillToggles = const {},
}) async {
  // User-level roots (~/.claude/skills, ~/.copilot/skills, ...) need the
  // real home directory - without it the desktop app only ever saw
  // project-local skills no matter what the consent said.
  final roots = defaultSkillRoots(
    cwd: env.cwd,
    homeDir: homeDir ?? desktopHomeDir(),
  );
  final skills = await discoverSkills(
    env,
    projectRoots: roots.projectRoots,
    userRoots: roots.userRoots,
    allowedSources: skillsAccessAllowsDiscovery(access, interactive: false)
        ? null
        : const {SkillSource.fah, SkillSource.agents},
    builtins: builtinSkills(),
  );
  final resolution = resolveSkillAvailability(
    skills: skills,
    scopes: [(SkillToggleScope.project, SkillsConfig(skills: skillToggles))],
  );
  final enabled = enabledSkills(skills, resolution);
  final contextFiles = await loadProjectContextFiles(env);
  return [
    if (formatProjectContext(contextFiles).isNotEmpty)
      formatProjectContext(contextFiles),
    if (formatSkillsForPrompt(enabled).isNotEmpty)
      formatSkillsForPrompt(enabled),
  ].join('\n\n');
}

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
    final suffix = await _discoverPromptSuffix(
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
