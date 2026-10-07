// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the per-skill availability members of
// [AgentService] live here (issue #1151) so the main file stays as close
// to the 2800-line guard as its pre-existing size allows. Same library,
// so private members resolve; the backing fields stay in the class body.

part of 'agent_service.dart';

/// Fingerprints of the pre-#1151 seeded skill copies this cleanup
/// retires: the old seeder wrote these files on every launch, so they
/// are ours, not user data, and a copy is removed ONLY when its SKILL.md
/// is byte-identical to the last seeded bytes (neither source carries
/// `fa-platforms` markers or `{{FA_PLATFORM}}`, so the seeder wrote
/// these bytes verbatim on every platform). Only SKILL.md goes — the
/// seeder never wrote anything else into those dirs, so a user-dropped
/// supporting file (script, prompt) survives (review -HUjo); an empty
/// leftover dir is invisible to discovery. Anything else is a deliberate
/// project override and stays — a customized create-goal keeps
/// shadowing the builtin (issue non-goal: migrating existing
/// overrides), an orphaned fa-self-config stops haunting every session
/// prompt.
const _staleSeedFingerprints = <String, String>{
  'create-goal':
      '427d831fa7c41b44a225f216a6e1961bf54b2821a538971e972dcee2c9383f72',
  'fa-self-config':
      '88c3301a46f5298255dc3f0e3f2b65bca3c5c97ade17e616ce5ad257c28f8dea',
};

/// gh-1164 Part A: js-apps promoted to a package builtin (source of truth
/// `prompts/skills/js-apps/SKILL.md`), retiring its bundled seed. Unlike
/// the skills above, the old seeder wrote
/// `filterPlatformInstructions(rawAsset, platform: currentFaPlatform)` —
/// the bytes it left on user machines VARY BY PLATFORM — so the cleanup
/// pins every historical per-platform variant and removes a copy when it
/// matches ANY of them. A user-customized copy keeps shadowing the
/// builtin. The raw pre-filter bytes are frozen at
/// `flutter_app/test/fixtures/retired_js_apps_skill.md`, pinned by
/// test/skills/retired_seed_frozen_test.dart.
const _staleBundledSeedFingerprints = <String, Set<String>>{
  'js-apps': {
    '83e0f64009b35bc96c0674fa3ec9d39a192a2cacce1ec942b32c026ff510375b', // macos
    '7ecb248a65728393d362a8a092f2d5a19d16e623b16d1776bab7ac339178a8b6', // ios
    '7ba90952131e1204e5240ca6e2e1c669fd55293b8e2b5cc69a19dadd1936dbce', // android
    '76cd5171a6e04ad52e2f772378a93a11e12b83b773bdde3685a3d1149e219c58', // windows
    '9336adfa3be78e0b890c520762aafe76c92ccf4913fc833e9c82f742b4a8e8de', // linux
    'c73012910a772db79dc19c7e2ad75b285cea24a25aecd77d1ca68d2dfa6f26ed', // web
  },
};

Future<void> _seedBundledSkills(ExecutionEnv env) async {
  for (final entry in _staleBundledSeedFingerprints.entries) {
    try {
      final body = (await env.readTextFile(
        '${env.cwd}/.fah/skills/${entry.key}/SKILL.md',
      )).valueOrNull;
      if (body == null) continue;
      if (!entry.value.contains(sha256.convert(utf8.encode(body)).toString())) {
        continue;
      }
      await env.remove('${env.cwd}/.fah/skills/${entry.key}/SKILL.md');
    } on Object {
      // best-effort cleanup
    }
  }
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
  // gh-1164 Part A: the bundled asset is gone — js-apps is a package
  // builtin now (builtinSkills(), merged by discoverSkills), so there is
  // nothing left to seed, only the retired copies above to clean up.
  await seedBuiltinSkillPointers(env);
}

/// gh-1393 AC7: make the compiled-in skills visible to agents that browse
/// the filesystem on hosts where the compiled-in SKILL.md text is only
/// reachable through the read tool (`builtin://skills/<name>/SKILL.md`).
/// Each builtin name gets `<env.cwd>/.fah/skills/<name>/SKILL.md.pointer`
/// whose body is the builtin read path — but ONLY when the directory is
/// missing or empty. A directory holding any real file is a deliberate
/// project copy and stays untouched (same contract as the cleanup above:
/// real skills always shadow builtins, and the discovery list merges the
/// builtins last anyway).
Future<void> seedBuiltinSkillPointers(ExecutionEnv env) async {
  for (final skill in builtinSkills()) {
    final dir = '${env.cwd}/.fah/skills/${skill.name}';
    try {
      await env.createDir(dir); // recursive; existing dir is not an error
      final entries = await env.listDir(dir);
      if ((entries.valueOrNull ?? const <FileInfo>[]).isNotEmpty) continue;
      await env.writeFile(
        '$dir/SKILL.md.pointer',
        '${builtinSkillPath(skill.name)}\n',
      );
    } on Object {
      // Pointer seeding is best-effort — a read-only or broken workspace
      // must not block startup.
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
