/// User consent for reading third-party agent configuration (skills and
/// subagent definitions) from the shared on-disk locations
/// (`.claude/`, `.github/`, `.codex/`, `.agents/`, `~/.claude/` …).
///
/// These directories contain instructions AND scripts that other tools
/// (Claude Code, GitHub Copilot, OpenAI Codex) drop onto the machine.
/// Discovery is ON BY DEFAULT ([granted]) so migrating users get their
/// existing skills with zero setup; [denied] opts out (settings / config),
/// and [ask] makes interactive hosts prompt at startup (headless runs treat
/// it as denied rather than silently reading third-party instruction files).
library;

/// The consent state for third-party skill/agent discovery.
enum SkillsAccess {
  /// Interactive hosts ask once at startup; headless runs behave like
  /// [denied] until the user answers. Never the default — only an explicit
  /// user choice.
  ask,

  /// Discovery is enabled. This is the DEFAULT.
  granted,

  /// Discovery is disabled: no third-party skill/agent file is read.
  denied,
}

/// Parses a persisted label (`ask`/`granted`/`denied`); null/unknown →
/// [SkillsAccess.granted] (discovery is opt-out, not opt-in).
SkillsAccess skillsAccessFromLabel(String? label) {
  return switch (label?.trim()) {
    'ask' => SkillsAccess.ask,
    'denied' => SkillsAccess.denied,
    _ => SkillsAccess.granted,
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
