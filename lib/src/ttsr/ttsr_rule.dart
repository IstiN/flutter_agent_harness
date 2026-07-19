/// TTSR rule and match-scope types.
///
/// Ported from oh-my-pi (`packages/coding-agent/src/capability/rule.ts` and
/// `export/ttsr.ts`), reduced to regex conditions: a rule carries one or more
/// regex [TtsrRule.patterns] (OR'd, omp's `condition`) matched against the
/// streaming text/thinking/tool-call deltas of a turn. omp's ast-grep
/// conditions, path globs, and per-rule `interruptMode` are deliberately not
/// ported (v1: regex only, matches always interrupt).
library;

/// Which stream a TTSR delta belongs to (omp's `TtsrMatchSource`).
enum TtsrMatchSource {
  /// Assistant prose (`text_delta`).
  text,

  /// Model reasoning (`thinking_delta`).
  thinking,

  /// Raw JSON argument fragments of a streaming tool call (`toolcall_delta`).
  tool,
}

/// Context about the stream content currently checked against TTSR rules
/// (omp's `TtsrMatchContext`, minus file-path candidates).
final class TtsrMatchContext {
  /// Creates a match context for [source].
  const TtsrMatchContext({required this.source, this.toolName, this.streamKey});

  /// Which stream the delta belongs to.
  final TtsrMatchSource source;

  /// Tool name for [TtsrMatchSource.tool] deltas, e.g. `edit`.
  final String? toolName;

  /// Stable key isolating buffering (e.g. `toolcall:<id>`), so concurrent
  /// tool-call argument streams don't bleed into each other.
  final String? streamKey;
}

/// The streams a rule monitors (omp's parsed `TtsrScope`).
///
/// Parsed from scope tokens: `text`, `thinking`, `tool`/`toolcall` (any
/// tool), `tool:<name>` or a bare `<name>` (that tool only). omp's
/// `tool(name)(pathGlob)` path scoping is not ported. The default scope
/// (omp's `DEFAULT_SCOPE`) watches text and all tools but not thinking.
final class TtsrScope {
  /// Creates a scope with explicit flags.
  const TtsrScope({
    this.allowText = true,
    this.allowThinking = false,
    this.allowAnyTool = true,
    this.toolNames = const {},
  });

  /// omp's default scope when a rule declares none.
  static const defaultScope = TtsrScope();

  /// Whether assistant prose is matched.
  final bool allowText;

  /// Whether thinking deltas are matched.
  final bool allowThinking;

  /// Whether every tool's argument stream is matched.
  final bool allowAnyTool;

  /// Named tools whose argument streams are matched (lower-case), used when
  /// [allowAnyTool] is false.
  final Set<String> toolNames;

  /// Parses scope tokens (omp's `buildScope`, without path globs).
  ///
  /// Unrecognized tokens are collected into [warnings] and skipped. When
  /// [tokens] is null or every token is empty, the [defaultScope] applies.
  static TtsrScope parse(
    List<String>? tokens, {
    required String ruleName,
    required List<String> warnings,
  }) {
    if (tokens == null || tokens.every((token) => token.trim().isEmpty)) {
      return defaultScope;
    }
    var allowText = false;
    var allowThinking = false;
    var allowAnyTool = false;
    final toolNames = <String>{};
    for (final raw in tokens) {
      final token = raw.trim();
      if (token.isEmpty) continue;
      final normalized = token.toLowerCase();
      switch (normalized) {
        case 'text':
          allowText = true;
        case 'thinking':
          allowThinking = true;
        case 'tool' || 'toolcall':
          allowAnyTool = true;
        default:
          // `tool:<name>` or a bare `<name>` (omp's tool-scope token,
          // path-glob suffix `(glob)` deliberately unsupported).
          final name = normalized.startsWith('tool:')
              ? normalized.substring('tool:'.length).trim()
              : normalized;
          if (RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) {
            toolNames.add(name);
          } else {
            warnings.add(
              'TTSR rule "$ruleName": invalid scope token "$raw", skipped',
            );
          }
      }
    }
    return TtsrScope(
      allowText: allowText,
      allowThinking: allowThinking,
      allowAnyTool: allowAnyTool,
      toolNames: toolNames,
    );
  }

  /// Whether any stream can match (omp's `hasReachableScope`).
  bool get isReachable =>
      allowText || allowThinking || allowAnyTool || toolNames.isNotEmpty;

  /// Whether this scope admits [context] (omp's `matchesScope`).
  bool matches(TtsrMatchContext context) {
    return switch (context.source) {
      TtsrMatchSource.text => allowText,
      TtsrMatchSource.thinking => allowThinking,
      TtsrMatchSource.tool =>
        allowAnyTool ||
            toolNames.contains(context.toolName?.trim().toLowerCase()),
    };
  }
}

/// A time-traveling stream rule (omp's `Rule`, reduced to regex conditions).
///
/// [patterns] are regex source strings (OR'd); the [TtsrManager] compiles
/// them at registration, skipping invalid ones with a warning. [body] is the
/// rule content injected as a system reminder when a pattern matches
/// mid-stream (omp's `Rule.content`).
final class TtsrRule {
  /// Creates a rule.
  const TtsrRule({
    required this.name,
    required this.patterns,
    required this.body,
    this.path,
    this.enabled = true,
    this.scope = TtsrScope.defaultScope,
  });

  /// Unique rule name; duplicate registrations are ignored (omp semantics).
  final String name;

  /// Regex sources matched against the scoped stream buffers (OR'd).
  final List<String> patterns;

  /// The injected rule content.
  final String body;

  /// Provenance rendered into the reminder envelope's `path` attribute
  /// (e.g. `~/.fah/config.yaml` or `.fah/rules.yaml`); `null` renders as
  /// `config`.
  final String? path;

  /// Disabled rules are skipped at registration.
  final bool enabled;

  /// The streams this rule monitors.
  final TtsrScope scope;
}
