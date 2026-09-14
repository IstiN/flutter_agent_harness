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
