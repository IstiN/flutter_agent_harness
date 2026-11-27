/// The workflow-log-fidelity resolution (gh-1433): which render defaults a
/// run gets, derived from its face.
///
/// One sentence: a non-interactive headless `fa -p` log reads back as the
/// full narrative of what the agent did and said — thinking, prose, tools —
/// with zero flags. The renderers already exist (gh-1198's dimmed thinking
/// deltas, the raw-surface text-delta streaming); this module decides WHICH
/// contexts get them by default:
///
/// - **log face** (headless `fa -p` — CI, bench, parent-CLI capture): the
///   post-hoc log IS the UI. Thinking deltas render dimmed and live;
///   assistant text streams live (the buffered-answer path never applies);
///   nothing re-ordered, nothing swallowed, nothing only-at-the-end.
/// - **interactive line mode**: today's opt-in (the gh-1198 byte-pin) —
///   thinking streams only through `--stream-thinking` /
///   `output.streamThinking`; the styled surface keeps buffering the
///   answer for its end-of-message markdown render.
/// - **TUI**: unchanged — its tiles already render everything.
///
/// Escape hatches, highest priority first (E3):
/// 1. `--no-stream-thinking` — restores legacy thinking silence for the
///    run (thinking-scoped: live text is the log face's primary channel
///    and stays live).
/// 2. `FA_LOG_FIDELITY=legacy` — the second-tier env override for edge
///    hosts that parse the log: reverts the whole face to the pre-flip
///    byte shape (thinking only through the setting; text per surface).
///    `full` (or anything else) keeps the face defaults.
/// 3. face defaults.
library;

/// Which render face a run drives (gh-1433).
enum LogFidelityFace {
  /// The interactive TUI — tiles already render thinking + text.
  tui,

  /// The interactive line-mode REPL — gh-1198's opt-in byte-pin.
  interactiveLine,

  /// The non-interactive headless face (`fa -p`, CI, bench, parent-CLI
  /// capture) — the log IS the UI.
  log,
}

/// The `FA_LOG_FIDELITY` env value that reverts a face to the pre-flip
/// byte shape (gh-1433 second tier).
const String logFidelityLegacyEnvValue = 'legacy';

/// The `FA_LOG_FIDELITY` env key (gh-1433 second tier).
const String logFidelityEnvKey = 'FA_LOG_FIDELITY';

/// The resolved render defaults for one run (gh-1433).
final class LogFidelity {
  /// Creates the resolved defaults.
  const LogFidelity({
    required this.streamThinking,
    required this.liveText,
  });

  /// Thinking deltas render dimmed, live (the gh-1198 tier-1 renderer).
  final bool streamThinking;

  /// Assistant text deltas stream live — the buffered-answer path never
  /// applies.
  final bool liveText;
}

/// Resolves the face from the two facts the CLI already carries: the TUI
/// gate (`useTui && io.supportsRawMode`) and the headless run gate
/// (`fa -p` / `--prompt-file` / positional prompt).
LogFidelityFace resolveLogFidelityFace({
  required bool useTui,
  required bool headlessRun,
}) {
  if (useTui) return LogFidelityFace.tui;
  return headlessRun ? LogFidelityFace.log : LogFidelityFace.interactiveLine;
}

/// Resolves the render defaults for one run (gh-1433).
///
/// [streamThinkingSetting] is the effective gh-1198 opt-in (`--stream-
/// thinking` flag OR the `output.streamThinking` config). [noStreamThinking]
/// is the `--no-stream-thinking` escape hatch — thinking-scoped, and it
/// beats the face default AND the env (E3: flag > env > face). [envFidelity]
/// is the raw `FA_LOG_FIDELITY` value; only [logFidelityLegacyEnvValue]
/// changes anything.
LogFidelity resolveLogFidelity({
  required LogFidelityFace face,
  required bool streamThinkingSetting,
  bool noStreamThinking = false,
  String? envFidelity,
}) {
  switch (face) {
    case LogFidelityFace.tui:
      // Unchanged (non-goal): the TUI always rendered everything.
      return const LogFidelity(streamThinking: true, liveText: true);
    case LogFidelityFace.interactiveLine:
      // The gh-1198 byte-pin: thinking stays opt-in, the styled surface
      // keeps buffering the answer for its end-of-message render.
      return LogFidelity(
        streamThinking: streamThinkingSetting,
        liveText: false,
      );
    case LogFidelityFace.log:
      final legacy =
          (envFidelity ?? '').trim().toLowerCase() ==
          logFidelityLegacyEnvValue;
      if (legacy) {
        // The second-tier revert: the exact pre-flip face — thinking only
        // through the setting, text per the surface's own mode.
        return LogFidelity(
          streamThinking: streamThinkingSetting,
          liveText: false,
        );
      }
      return LogFidelity(
        // The flip: the log face renders thinking by default; the escape
        // hatch silences it for the run (thinking-scoped — live text is
        // the log's primary channel and stays live).
        streamThinking: !noStreamThinking,
        liveText: true,
      );
  }
}
