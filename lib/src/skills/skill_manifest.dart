/// Typed skill frontmatter: the Agent Skills open-standard fields
/// (`name`/`description`/`license`/`compatibility`/`metadata`/
/// `allowed-tools`) plus the Claude Code extension vocabulary
/// (`when_to_use`, `arguments`, `disable-model-invocation`, `user-invocable`,
/// `disallowed-tools`, `model`, `effort`, `context: fork`, `agent`,
/// `background`, `hooks`, `paths`, `shell`) and the GitHub Copilot
/// instruction fields (`applyTo`, `excludeAgent`). Codex skills use only
/// `name`/`description`, which this parser covers by construction.
///
/// Unknown keys never break loading: they are collected into [notes] so the
/// host can surface them, while the skill still works with the fields it
/// understands (multi-format portability rule).
library;

/// One parsed skill frontmatter.
final class SkillManifest {
  const SkillManifest({
    this.description,
    this.whenToUse,
    this.argumentHint,
    this.arguments = const [],
    this.disableModelInvocation = false,
    this.userInvocable = true,
    this.allowedTools = const [],
    this.disallowedTools = const [],
    this.model,
    this.effort,
    this.contextFork = false,
    this.agent,
    this.background = true,
    this.paths = const [],
    this.shell,
    this.license,
    this.compatibility,
    this.metadata = const {},
    this.applyTo = const [],
    this.excludeAgent,
    this.notes = const [],
  });

  /// An empty manifest (skill file without frontmatter).
  static const empty = SkillManifest();

  /// Frontmatter `description` (null → the host falls back to the first
  /// non-empty body line).
  final String? description;

  /// Claude's `when_to_use` — extra trigger hints appended to the
  /// description in catalog listings.
  final String? whenToUse;

  /// Claude's `argument-hint` (autocomplete placeholder).
  final String? argumentHint;

  /// Claude's `arguments` — named positional args for `$name` substitution.
  final List<String> arguments;

  /// Claude's `disable-model-invocation`: only the user may run it.
  final bool disableModelInvocation;

  /// Claude's `user-invocable: false`: only the model may load it.
  final bool userInvocable;

  /// Agent Skills spec `allowed-tools`: tool names the skill may use
  /// without a prompt during the invoking turn. Pattern entries
  /// (`Bash(git status:*)`) are kept verbatim but only plain tool names take
  /// effect (see [plainAllowedTools]).
  final List<String> allowedTools;

  /// Claude's `disallowed-tools`: tools removed while the skill is active
  /// (turn-scoped deny).
  final List<String> disallowedTools;

  /// Claude/Copilot `model`: a model id or role hint for the invoking turn.
  final String? model;

  /// Claude's `effort` override (`low`/`medium`/`high`/…). Parsed but only
  /// informational until a provider mapping exists.
  final String? effort;

  /// Claude's `context: fork` — run the skill body as a subagent prompt.
  final bool contextFork;

  /// Claude's `agent`: the subagent type to use with [contextFork].
  final String? agent;

  /// Claude's `background` (only with [contextFork]): `false` waits for the
  /// forked subagent's result in the invoking turn. Default true.
  final bool background;

  /// Claude's `paths` glob activation list.
  final List<String> paths;

  /// Claude's `shell` for injected commands (`bash`/`powershell`).
  final String? shell;

  /// Agent Skills spec `license`.
  final String? license;

  /// Agent Skills spec `compatibility` (≤500 chars per spec; not enforced).
  final String? compatibility;

  /// Agent Skills spec `metadata` (free-form map, host tooling only).
  final Map<String, Object?> metadata;

  /// Copilot instructions `applyTo` glob list (path-specific activation).
  final List<String> applyTo;

  /// Copilot instructions `excludeAgent` (`code-review`/`cloud-agent`).
  final String? excludeAgent;

  /// Non-fatal parse notes (unknown keys, pattern-only tool grants, …).
  final List<String> notes;

  /// [allowedTools] entries that are plain tool names (no pattern suffix) —
  /// the only ones our per-tool approval gate can honor today.
  List<String> get plainAllowedTools =>
      allowedTools.where((t) => !t.contains('(')).toList();

  /// The catalog description: `description` plus Claude's `when_to_use`
  /// appended (Claude concatenates both into the listing, capped at 1536
  /// chars; we keep the same concatenation, the host applies its budget).
  String? get catalogDescription {
    final desc = description;
    final when = whenToUse;
    if (desc == null || desc.isEmpty) {
      return (when?.isEmpty ?? true) ? null : when;
    }
    if (when == null || when.isEmpty) return desc;
    return '$desc $when';
  }

  /// Parses one frontmatter map (from `parseFrontmatterTyped`).
  factory SkillManifest.fromFrontmatter(
    Map<String, Object?> frontmatter, {
    String skillName = '',
  }) {
    final notes = <String>[];
    String label(String key) =>
        skillName.isEmpty ? '"$key"' : 'skill "$skillName": "$key"';

    String? asString(String key) {
      final value = frontmatter[key];
      if (value == null) return null;
      if (value is String) return value.trim().isEmpty ? null : value.trim();
      return '$value';
    }

    bool asBool(String key, bool fallback) {
      final value = frontmatter[key];
      if (value == null) return fallback;
      if (value is bool) return value;
      final text = '$value'.toLowerCase().trim();
      return switch (text) {
        'true' || 'yes' || 'on' || '1' => true,
        'false' || 'no' || 'off' || '0' => false,
        _ => fallback,
      };
    }

    List<String> asStringList(String key) {
      final value = frontmatter[key];
      if (value == null) return const [];
      if (value is List) {
        return [
          for (final item in value)
            if ('$item'.trim().isNotEmpty) '$item'.trim(),
        ];
      }
      // Claude accepts space- or comma-separated strings; Copilot uses
      // comma-separated `applyTo` strings.
      return '$value'
          .split(RegExp(r'[,\s]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    // Known keys across the three supported formats. Anything else is kept
    // as a note (never fatal) — multi-format portability.
    const knownKeys = {
      // Agent Skills spec
      'name', 'description', 'license', 'compatibility', 'metadata',
      'allowed-tools',
      // Claude Code extensions
      'when_to_use', 'argument-hint', 'arguments', 'disable-model-invocation',
      'user-invocable', 'disallowed-tools', 'model', 'effort', 'context',
      'agent', 'background', 'hooks', 'paths', 'shell',
      // GitHub Copilot instruction files
      'applyTo', 'excludeAgent',
    };
    for (final key in frontmatter.keys) {
      if (!knownKeys.contains(key)) {
        notes.add('${label(key)} unknown frontmatter key (ignored)');
      }
    }

    final allowed = asStringList('allowed-tools');
    final patterned = allowed.where((t) => t.contains('(')).toList();
    if (patterned.isNotEmpty) {
      notes.add(
        '${label('allowed-tools')} pattern entries not supported yet: '
        '${patterned.join(', ')} — only plain tool names are granted',
      );
    }
    if (frontmatter['hooks'] != null) {
      notes.add('${label('hooks')} hooks are not supported yet (ignored)');
    }

    final metadataValue = frontmatter['metadata'];
    return SkillManifest(
      description: asString('description'),
      whenToUse: asString('when_to_use'),
      argumentHint: asString('argument-hint'),
      arguments: asStringList('arguments'),
      disableModelInvocation: asBool('disable-model-invocation', false),
      userInvocable: asBool('user-invocable', true),
      allowedTools: allowed,
      disallowedTools: asStringList('disallowed-tools'),
      model: asString('model'),
      effort: asString('effort'),
      contextFork: asString('context') == 'fork',
      agent: asString('agent'),
      background: asBool('background', true),
      paths: asStringList('paths'),
      shell: asString('shell'),
      license: asString('license'),
      compatibility: asString('compatibility'),
      metadata: metadataValue is Map
          ? {
              for (final entry in metadataValue.entries)
                '${entry.key}': entry.value,
            }
          : const {},
      applyTo: asStringList('applyTo'),
      excludeAgent: asString('excludeAgent'),
      notes: notes,
    );
  }
}
