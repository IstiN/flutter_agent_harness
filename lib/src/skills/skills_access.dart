/// User consent for reading third-party agent configuration (skills and
/// subagent definitions) from the shared on-disk locations
/// (`.claude/`, `.github/`, `.codex/`, `.agents/`, `~/.claude/` …).
///
/// These directories contain instructions AND scripts that other tools
/// (Claude Code, GitHub Copilot, OpenAI Codex) drop onto the machine. Reading
/// them hands that content to the model, so discovery only runs after the
/// user opts in — see `skills_access.md` docs. [ask] means "no decision yet":
/// interactive hosts show a one-time dialog, non-interactive runs skip
/// discovery (safe default).
library;

/// The consent state for third-party skill/agent discovery.
enum SkillsAccess {
  /// No decision recorded yet: interactive hosts ask once, headless runs
  /// behave like [denied] until the user answers.
  ask,

  /// Discovery is enabled.
  granted,

  /// Discovery is disabled: no third-party skill/agent file is read.
  denied,
}

/// Parses a persisted label (`ask`/`granted`/`denied`); null/unknown →
/// [SkillsAccess.ask].
SkillsAccess skillsAccessFromLabel(String? label) {
  return switch (label?.trim()) {
    'granted' => SkillsAccess.granted,
    'denied' => SkillsAccess.denied,
    _ => SkillsAccess.ask,
  };
}

/// The persisted label of [access].
String skillsAccessLabel(SkillsAccess access) => access.name;

/// Whether third-party skill/agent discovery may read from disk.
///
/// [interactive] mirrors the host's ability to ask: a non-interactive run
/// (headless CLI, background agent) treats an undecided [ask] state as
/// denied rather than silently reading third-party instruction files.
bool skillsAccessAllowsDiscovery(
  SkillsAccess access, {
  required bool interactive,
}) {
  return switch (access) {
    SkillsAccess.granted => true,
    SkillsAccess.denied => false,
    // `ask` in an interactive host is resolved by the prompt BEFORE
    // discovery runs, so reaching this call still means "not yet answered".
    SkillsAccess.ask => false,
  };
}
