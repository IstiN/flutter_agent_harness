/// The clipboard-paste zone (issue #276) — split out of `fa_tui.dart` to
/// keep it under the repo's 2800-line size gate. Same library (a `part
/// of`), so the extension sees FaTuiModel's private members (`_appendOutput`,
/// `outputLines`, `attachments`). Bracketed-paste routing lives here too
/// (issue #1067): it grew this same zone instead of `fa_tui.dart`.
part of 'fa_tui.dart';

/// The async pasteboard read landed; carries image bytes or the named
/// failure reason. [silentFailure] marks the bracketed-paste probes
/// (issue #1067): a plain-text paste must never print clipboard errors,
/// so failed probes stay quiet — only Ctrl+V and image-intent pastes
/// (empty payload) name their failures.
final class PasteboardResultMsg extends Msg {
  PasteboardResultMsg(this.read, {this.silentFailure = false});
  final PasteboardRead read;
  final bool silentFailure;
}

/// Ctrl+V pressed while a prompt sheet is open: the async answer to the key
/// [_handlePromptKey] intercepted. Carries what the clipboard returned — the
/// sheet decides how much of it it can take — plus the [gestureMs] stamp of
/// the paste gesture that fired it, so a bracketed paste which took the same
/// gesture over can suppress this late result (review of PR #1974).
final class PromptClipboardTextMsg extends Msg {
  PromptClipboardTextMsg(this.read, this.gestureMs);
  final PasteboardRead read;
  final int gestureMs;
}

/// How long a fired pasteboard probe owns the paste gesture (issue #1067):
/// the Ctrl+V key event and the terminal's bracketed paste of ONE action
/// arrive back to back, and tmux/screen split large pastes into adjacent
/// blocks. Within this window the second path never fires a second probe —
/// one gesture is one subprocess read and can never stack two chips, no
/// matter when the concurrent reads land or whether the clipboard changed.
const int _pasteboardGestureWindowMs = 500;

extension FaTuiPaste on FaTuiModel {
  /// Ctrl+V outcome: image bytes become a composer chip; a TEXT result
  /// (the gh-1575 fallback) is inserted into the composer; failures print
  /// their NAMED reason (unavailable pasteboard, size cap, not an image).
  UiUpdate _handlePasteboardResult(PasteboardResultMsg msg) {
    final read = msg.read;
    // gh-1575: the image probe missed and the text clipboard came back —
    // paste the text the way a terminal's own paste would have.
    if (read is PasteboardText) {
      return (copyWith(editor: editor.insert(read.text)), null);
    }
    if (read is! PasteboardImage) {
      if (msg.silentFailure) return (this, null);
      final reason = read is PasteboardUnavailable
          ? read.reason
          : 'clipboard read failed';
      return (_appendServiceLine(_dim(reason)), null);
    }
    final error = pasteImageError(read.bytes);
    if (error != null) {
      if (msg.silentFailure) return (this, null);
      return (_appendServiceLine(_dim(error)), null);
    }
    final mime = sniffImageMime(read.bytes)!;
    final attachment = TuiImageAttachment(
      name: 'clipboard-${attachments.length + 1}.${imageMimeExtension(mime)}',
      mimeType: mime,
      bytes: read.bytes,
    );
    return (copyWith(attachments: [...attachments, attachment]), null);
  }

  /// True while a probe from this paste gesture is still current.
  bool _pasteboardProbeInFlight() =>
      nowFn().millisecondsSinceEpoch - _pasteboardProbeFiredAtMs <
      _pasteboardGestureWindowMs;

  /// Fires [reader] off the UI loop, stamping the gesture on the returned
  /// model — or a silent no-op when a gesture probe is already in flight.
  /// [silentFailure] keeps bracketed-paste failures quiet.
  FaTuiUpdate _firePasteboardProbe(
    Future<PasteboardRead> Function() reader, {
    required bool silentFailure,
  }) {
    if (_pasteboardProbeInFlight()) return (this, null);
    final armed = copyWith();
    armed._pasteboardProbeFiredAtMs = nowFn().millisecondsSinceEpoch;
    return (armed, _pasteboardProbe(reader, silentFailure: silentFailure));
  }

  /// One async pasteboard probe; the outcome lands back as a
  /// [PasteboardResultMsg]. The reader is handed in by a caller that has
  /// already checked [FaTuiCallbacks.readClipboardImage].
  Cmd _pasteboardProbe(
    Future<PasteboardRead> Function() reader, {
    required bool silentFailure,
  }) =>
      () async =>
          PasteboardResultMsg(await reader(), silentFailure: silentFailure);

  /// Ctrl+V (issue #276): read the platform pasteboard off the UI loop and
  /// attach the image as a composer chip. Without a wired reader (or in
  /// prompt mode) this is a no-op — the prompt zone owns plain pastes.
  /// gh-1575: when the image probe misses and a text reader is wired, the
  /// probe falls through to the clipboard's TEXT and the composer inserts
  /// it (Ctrl+V used to dead-end on `clipboard holds no image` for a text
  /// clipboard). Bracketed pastes probe through [_handlePaste] with the
  /// same seam and the same gesture pairing (issue #1067), keeping this
  /// keybinding working identically.
  UiUpdate? _handlePasteImageKey(KeyMsg msg) {
    if (msg.key != 'ctrl+v') return null;
    final reader = callbacks.readClipboardImage;
    if (reader == null) {
      return (_appendServiceLine(_dim(clipboardUnavailableHint)), null);
    }
    final textReader = callbacks.readClipboardText;
    return _firePasteboardProbe(
      textReader == null
          ? reader
          : () async {
              final read = await reader();
              if (read is PasteboardImage) return read;
              final text = await textReader();
              if (text is PasteboardText && text.text.isNotEmpty) return text;
              return read; // neither reachable: the named reason prints
            },
      silentFailure: false,
    );
  }

  /// dart_tui 2.0.0's bracketed-paste decoder maps every pasted BYTE to a
  /// char code (Latin-1), so pasted non-ASCII text arrives as mojibake
  /// ("ÐÑÐ¸Ð²ÐµÑ" instead of "Привет"). The mis-decode is lossless —
  /// re-encoding as Latin-1 recovers the original bytes — so decode them as
  /// UTF-8 here. ASCII and already-correct input pass through unchanged.
  static String _fixPasteMojibake(String text) {
    try {
      return utf8.decode(latin1.encode(text));
    } on Object {
      return text; // never worse than the input
    }
  }

  /// Ctrl+V inside a prompt sheet: feed the sheet the clipboard's text
  /// through the SAME [_handlePaste] branch a terminal paste takes, so the
  /// secret masking, CRLF normalisation, name trimming and enter-resolution
  /// stay one implementation. A non-text read, an empty payload, or a sheet
  /// that closed while the read was in flight are no-ops — the pre-existing
  /// silent behaviour for those cases.
  UiUpdate _handlePromptClipboardText(PromptClipboardTextMsg msg) {
    final read = msg.read;
    if (read is! PasteboardText || read.text.isEmpty) return (this, null);
    // The sheet closed while the read was in flight: drop the result rather
    // than re-opening a sheet the user already dismissed (or rerouting the
    // secret into the composer).
    if (prompt == null) return (this, null);
    // A bracketed paste took this gesture over while the read was in flight:
    // its payload is already in the sheet, so this copy must not land.
    if (msg.gestureMs != _pasteboardProbeFiredAtMs) return (this, null);
    return _pasteIntoPrompt(read.text);
  }

  /// Applies [content] to the open sheet exactly as a terminal paste does
  /// (`PromptPaste`: masking, CRLF normalisation, name trimming), resolving the
  /// sheet when the payload completes it. Shared by the bracketed-paste path
  /// and the Ctrl+V clipboard read so both keep ONE insertion contract.
  UiUpdate _pasteIntoPrompt(String content) {
    final (state: next, resolved: answer) = handleTuiPromptKey(
      prompt!,
      PromptPaste(content),
    );
    if (answer != null) {
      _promptCompleter?.complete(answer);
      _promptCompleter = null;
      return (copyWith(clearPrompt: true), null);
    }
    return (copyWith(prompt: next), null);
  }

  UiUpdate _handlePaste(PasteMsg msg) {
    final content = _fixPasteMojibake(msg.content);
    // Prompt mode: pastes go into the open prompt's buffer (e.g. an API key
    // pasted into the dial/secret prompts), like typed characters do — and
    // never probe the clipboard (issue #1067 AC4: pasted secrets stay
    // plain text).
    if (prompt != null) {
      // One gesture, one insertion (issue #1067, review of PR #1974): the
      // Ctrl+V key that fired a clipboard read for THIS gesture already owns
      // the payload — inserting the bracketed twin as well put the token in
      // the sheet twice ("sk-tokensk-token"), silently behind the masking.
      if (_pasteboardProbeInFlight()) return (this, null);
      // A bracketed paste can be the FIRST carrier of the gesture too: arm the
      // window so the twin ctrl+v key, or a late clipboard result, is dropped.
      final armed = copyWith();
      armed._pasteboardProbeFiredAtMs = nowFn().millisecondsSinceEpoch;
      final (next, cmd) = armed._pasteIntoPrompt(content);
      return (next, cmd);
    }
    // Any paste action also probes the clipboard for images (issue #1067):
    // terminal-menu Paste / Cmd+V arrive as bracketed paste, never as the
    // ctrl+v key event. One probe per gesture — [_firePasteboardProbe]
    // absorbs the ctrl+v twin and tmux's split blocks. Additive: text
    // insertion is unchanged; failures stay silent for text pastes but are
    // NAMED when the payload is empty (the terminal's image-paste gesture,
    // where the user clearly tried to paste something).
    final reader = callbacks.readClipboardImage;
    if (reader == null) {
      return (copyWith(editor: editor.insert(content)), null);
    }
    final (armed, probe) = _firePasteboardProbe(
      reader,
      silentFailure: content.isNotEmpty,
    );
    return (armed.copyWith(editor: editor.insert(content)), probe);
  }
}
