/// The host-supplied callback surface ([FaTuiCallbacks]) — split out of
/// `fa_tui.dart` to keep it under the repo's 2800-line size gate (the
/// gh-1575 `readClipboardText` wiring pushed the file over; same library,
/// a `part of`, so no public API moves and importers see no change).
part of 'fa_tui.dart';

/// Host callbacks supplied by [AgentCli] to the dart_tui REPL.
final class FaTuiCallbacks {
  const FaTuiCallbacks({
    required this.onSubmit,
    required this.onModelSelected,
    required this.buildSlashMenu,
    required this.buildModelMenu,
    required this.statusLine,
    required this.prompt,
    this.onInterrupt,
    this.onCtrlCExit,
    this.isShiftPressed,
    this.opensPicker,
    this.onPickerSelected,
    this.onPickerCancelled,
    this.onSteer,
    this.pathCandidates,
    this.onHubAction,
    this.readClipboardImage,
    this.readClipboardText,
    this.statusSnapshot,
    this.statusLineEngine,
  });

  /// Called when the user submits a non-empty input line. [images] carries
  /// the clipboard chips attached via Ctrl+V (empty for slash/bang
  /// commands — those never consume attachments).
  final Future<void> Function(String line, {List<TuiImageAttachment> images})
  onSubmit;

  /// Called when the user picks a model from the picker.
  final Future<void> Function(String modelId) onModelSelected;

  /// Builds slash-command menu items for the given prefix.
  final List<MenuItem> Function(String prefix) buildSlashMenu;

  /// Builds model-picker menu items (the resolved table) for the filter at
  /// the given terminal width — the width drives the column elision.
  final List<MenuItem> Function(String filter, int width) buildModelMenu;

  /// One-line status shown above the input line.
  final String Function() statusLine;

  /// Host-built status-bar frame data (issue #806, the S3 band
  /// attachment): the host resolves the snapshot per frame tick — the
  /// TUI layer performs zero fetches and zero subprocess calls. NULL
  /// means the legacy composer (the `tui.classic` kill switch, or the
  /// web stub): the dim one-line footer stays, byte-identical.
  final StatusLineSnapshot Function()? statusSnapshot;

  /// The status-line engine (spec resolved once from `tui.statusLine`
  /// config). Supplied together with [statusSnapshot]; the band writer
  /// renders it per frame at the composer's top.
  final TuiStatusLine? statusLineEngine;

  /// The input prompt (e.g. `fa> `).
  final String prompt;

  /// Called on Ctrl-C while the agent is busy.
  final void Function()? onInterrupt;

  /// Double-press Ctrl+C exit (issue #830): press 2 within the window
  /// resolved [SigintAction.exitInteractive] — the host runs the
  /// SIGINT-parity exit (abort-if-running bounded, session resume hint,
  /// exit 130). Null falls back to a plain `quit()` (exit 0), the
  /// single-press behavior this issue replaced.
  final void Function()? onCtrlCExit;

  /// Host-provided Shift modifier check (e.g. macOS Core Graphics via FFI).
  /// When null, Shift+Enter is not specially handled.
  final bool Function()? isShiftPressed;

  /// Slash commands that open a host-side picker when accepted from the
  /// command menu (e.g. `/sessions`, `/mode`, `/approval`): the command is
  /// submitted immediately instead of being filled into the input.
  final bool Function(String key)? opensPicker;

  /// Called when a generic picker (opened via [FaTuiController.openPicker])
  /// resolves — [pickerId] identifies which picker, [key] the chosen item.
  final Future<void> Function(String pickerId, String key)? onPickerSelected;

  /// Called when a generic picker is dismissed with Esc without a selection
  /// (wizard flows wait on the answer and must not hang). The models picker
  /// never reports here (Esc there is plain "close").
  final void Function(String pickerId)? onPickerCancelled;

  /// Called to steer messages into the RUNNING agent (Ctrl+S while busy,
  /// kimi-cli semantics): each message is injected as a separate user
  /// message mid-turn.
  final Future<void> Function(List<String> messages)? onSteer;

  /// Workspace file paths for the composer's fuzzy path completion
  /// (`@token` and shell words on a `!` line, issue #275 AC1). Called per
  /// keystroke — the host must cache the listing (the issue's "candidates
  /// cached" clause). Null disables path completion.
  final List<String> Function(String fragment)? pathCandidates;

  /// Reads the platform pasteboard for an image (Ctrl+V). Null = no
  /// reader wired (prints the unavailable hint). Runs OFF the UI loop —
  /// the result comes back as a [PasteboardResultMsg].
  final Future<PasteboardRead> Function()? readClipboardImage;

  /// Reads the platform pasteboard's plain text (gh-1575): the Ctrl+V
  /// image-probe fallback — when the pasteboard holds no image, the text
  /// is inserted into the composer instead of printing the dead-end
  /// reason. Null = no fallback (the named reason prints as before).
  final Future<PasteboardRead> Function()? readClipboardText;

  /// Agents-hub overlay actions (issue #277): [FaHubAction.enter] drills
  /// into the selected agent's transcript ([key] = row key), back returns
  /// from a transcript to the tree, close hides the overlay. The host
  /// pushes fresh [HubStateMsg] content in response.
  final Future<void> Function(String action, String? key)? onHubAction;
}
