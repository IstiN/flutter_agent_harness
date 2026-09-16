part of 'fa_tui.dart';

/// Message carrying host output into the TUI.
final class OutputMsg extends Msg {
  OutputMsg(this.text, {this.newline = false});

  final String text;
  final bool newline;
}

/// Message replacing the composer text (the `/skills` menu prefills
/// `/skill:<name> ` so the user can add arguments before sending).
final class _SetInputTextMsg extends Msg {
  _SetInputTextMsg(this.text);
  final String text;
}

/// Message replacing the submitted-message history (a resumed session
/// restores its recorded messages so ↑ recalls them instead of scrolling).
final class SetInputHistoryMsg extends Msg {
  SetInputHistoryMsg(this.history);
  final List<String> history;
}

/// Message asking the model picker to refresh its items.
final class _ModelsRefreshMsg extends Msg {}

/// Message announcing a session theme switch (issue #279): invalidates
/// rendered-color caches; the next frame repaints in the new palette.
final class _ThemeChangedMsg extends Msg {}

/// Message asking the model picker to open.
final class _OpenModelMenuMsg extends Msg {}

/// Message opening a generic host picker (sessions, mode, approval, ...).
final class OpenPickerMsg extends Msg {
  OpenPickerMsg(this.pickerId, this.title, this.items, {this.initialIndex = 0});
  final String pickerId;
  final String title;
  final List<MenuItem> items;

  /// The initially highlighted item (wizard prefills).
  final int initialIndex;
}

/// Message asking the program to quit because the host marked exit.
final class _QuitRequestedMsg extends Msg {}

/// Message toggling the busy ("thinking") indicator while a run streams.
final class BusyMsg extends Msg {
  const BusyMsg(this.busy, {this.phase, this.source});

  /// `true` starts a busy stretch, `false` ends it.
  final bool busy;

  /// Silent post-answer phase label ("Compacting context…"). Non-null on an
  /// ALREADY-busy message means relabel-only: the spinner chain and the
  /// elapsed window stay untouched.
  final String? phase;

  /// Who armed/released the row ('run', 'submit', …) — rendered next to the
  /// label and logged on every transition so a wedged row names its owner.
  final String? source;
}

/// Busy-row forensic sink: the host (agent_cli) points this at its
/// diagnostic log so every arm/release/relabel/drop/watchdog-fire is
/// attributable — the answer to "who left Working… on".
void Function(String line)? faTuiBusyDiagnostics;

/// Internal spinner-frame tick; re-scheduled while the model stays busy.
final class SpinnerTickMsg extends Msg {}

/// Host push of the pending scheduled follow-up count (`schedule_message`
/// records): rendered as a dim row on top of the busy row (issue #115).
final class ScheduledStatusMsg extends Msg {
  const ScheduledStatusMsg(this.count, this.nextDueMs);

  /// Deliverable pending records.
  final int count;

  /// Earliest due time (epoch ms); null when unknown.
  final int? nextDueMs;
}

/// Host push of the visible-waiting row state (issue #450): the waiter
/// aggregate — running background jobs (render purposes), armed self-wake
/// timers (absolute due epoch ms + preview) — and how many background
/// jobs a previous run lost. The host pushes on every waiter enter/leave;
/// the row is never polled per frame.
final class WaitingStatusMsg extends Msg {
  const WaitingStatusMsg({
    required this.jobs,
    required this.timers,
    this.lostJobs = 0,
  });

  /// Running background jobs, one purpose per job (command + id).
  final List<String> jobs;

  /// Armed timers: due epoch ms + text preview.
  final List<({int dueMs, String preview})> timers;

  /// Background jobs the previous run of this session left running.
  final int lostJobs;
}

/// Host push of the background-job board's live region (issue #429): the
/// summary lines and live rows for the transient area above the busy row.
/// Plain strings — the model clips per frame at the live width.
final class JobBoardMsg extends Msg {
  const JobBoardMsg(this.lines);

  /// Pre-rendered live lines (possibly empty — hides the region).
  final List<String> lines;
}

/// One-shot minute-boundary tick keeping the scheduled-follow-ups
/// indicator's "next in Nm" countdown live while the TUI is idle (issue
/// #213): the row recomputes from the clock at render time, so the tick
/// only triggers a repaint and re-arms.
final class ScheduledTickMsg extends Msg {
  const ScheduledTickMsg();
}

/// Message draining the queued messages (kimi-cli semantics: after a run
/// settles the host takes them one-by-one as separate turns). The model
/// echoes them into the history before clearing.
final class DrainQueueMsg extends Msg {
  DrainQueueMsg(this.completer);
  final Completer<List<String>> completer;
}

/// Message clearing the queued messages without running them (`/queue
/// clear`, issue #275): the visible strip is the user's contract that
/// these texts are pending — a silent clear would be a lost message.
final class ClearQueueMsg extends Msg {
  const ClearQueueMsg();
}

/// Message opening the interactive prompt zone (ask/secret/approval).
final class OpenPromptMsg extends Msg {
  OpenPromptMsg(this.spec, this.completer);
  final TuiPromptSpec spec;
  final Completer<TuiPromptAnswer?> completer;
}

/// Message opening or refreshing the agents-hub overlay (issue #277).
final class HubStateMsg extends Msg {
  HubStateMsg(this.state, {this.refreshOnly = false});
  final FaHubState state;

  /// Refresh-only push (issue #382): the model drops it while the overlay
  /// is closed — background events may refresh an open hub, never open one.
  final bool refreshOnly;
}

/// Message hiding the agents-hub overlay (issue #277).
final class _CloseHubMsg extends Msg {
  const _CloseHubMsg();
}

/// ─── Output-history append machinery (moved out of FaTuiModel to keep
/// the model file under the 2800-line gate; same library, same members) ───
  /// Matches a code-fence opener/closer line exactly like the view-time
  /// markdown walk (ansi_markdown.dart `_fenceRe`): parity over the
  /// retained history must agree with what the renderer will compute.
final RegExp _fenceLineStart = RegExp(r'^\s*```');

List<String> _appendToHistory(
    List<String> lines,
    String text,
    bool newline,
  ) {
    if (text.isEmpty && !newline) return lines;
    final result = List.of(lines);
    final parts = text.split('\n');
    if (result.isEmpty) result.add('');
    result[result.length - 1] += parts.first;
    for (var i = 1; i < parts.length; i++) {
      result.add(parts[i]);
    }
    if (newline) result.add('');
    // A streamed paragraph with no trailing newline grows the last line
    // without bound: minutes-long thinking bursts produced HUNDRED-KB
    // lines, and TranscriptMarkdown's (throttled) tail passes re-format +
    // re-wrap the WHOLE line each pass — the event loop stalled in bursts
    // and typing froze. Cap the tail: hard-split an oversized last line
    // into bounded chunks. Soft wrap renders them identically (the text
    // continues at the same cell); only an inline span crossing the rare
    // split point loses its styling into the next chunk.
    const maxTailLineChars = 32 * 1024;
    const tailChunkChars = 16 * 1024;
    if (result.last.length > maxTailLineChars) {
      final tail = result.last;
      result
        ..removeLast()
        ..addAll([
          for (var i = 0; i < tail.length; i += tailChunkChars)
            tail.substring(i, (i + tailChunkChars).clamp(0, tail.length)),
        ]);
    }
    // Keep the history bounded — but AMORTIZED. Trimming back to exactly
    // maxLines on EVERY append drops the oldest line each flush, and a
    // changed first line breaks TranscriptMarkdown's boundary identity, so
    // once an answer crossed the cap every 50 ms streaming flush paid a
    // full O(history) formatAll+wrap pass (~27 ms at 2000 lines — over half
    // the flush budget): constant scroll/typing jank for long answers. A
    // slack window lets ordinary appends stay on the incremental path; one
    // batch rebuild per [trimSlack] dropped lines is imperceptible.
    const maxLines = 2000;
    const trimSlack = 400;
    if (result.length > maxLines + trimSlack) {
      // A cut landing inside a fenced code block leaves the retained
      // history with an open fence: the block's closing ``` then toggles
      // the walk OPEN and every markdown line after it renders verbatim
      // (raw **/### walls after a long stream). Count fence lines in the
      // DROPPED head — the state the rebuilt walk starts in — and prepend
      // a synthetic closing fence when it is open. The same trick
      // tui_replay.dart uses for truncated replays.
      final cut = result.length - maxLines;
      var open = false;
      for (var i = 0; i < cut; i++) {
        if (_fenceLineStart.hasMatch(result[i])) open = !open;
      }
      final trimmed = result.sublist(cut);
      if (open) trimmed.insert(0, '```');
      return trimmed;
    }
    return result;
  }
