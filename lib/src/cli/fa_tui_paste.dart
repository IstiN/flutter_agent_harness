/// The clipboard-paste zone (issue #276) — split out of `fa_tui.dart` to
/// keep it under the repo's 2800-line size gate. Same library (a `part
/// of`), so the extension sees FaTuiModel's private members (`_appendOutput`,
/// `outputLines`, `attachments`).
part of 'fa_tui.dart';

/// The async pasteboard read landed; carries image bytes or the named
/// failure reason. [silentFailure] marks the bracketed-paste probes
/// (issue #1067): a plain-text paste must never print clipboard errors,
/// so failed probes stay quiet — only Ctrl+V names its failures.
final class PasteboardResultMsg extends Msg {
  PasteboardResultMsg(this.read, {this.silentFailure = false});
  final PasteboardRead read;
  final bool silentFailure;
}

/// How long two identical probe results count as one user paste
/// (issue #1067): Ctrl+V and the bracketed paste of the same action arrive
/// within milliseconds of each other and must not stack two chips.
const int _pasteboardDedupeWindowMs = 500;

bool _bytesEqual(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

extension FaTuiPaste on FaTuiModel {
  /// Ctrl+V outcome: image bytes become a composer chip; failures print
  /// their NAMED reason (unavailable pasteboard, size cap, not an image).
  (Model, Cmd?) _handlePasteboardResult(PasteboardResultMsg msg) {
    final read = msg.read;
    if (read is! PasteboardImage) {
      if (msg.silentFailure) return (this, null);
      final reason = read is PasteboardUnavailable
          ? read.reason
          : 'clipboard read failed';
      return (
        copyWith(
          outputLines: FaTuiModel._appendOutput(
            outputLines,
            _dim(reason),
            true,
          ),
        ),
        null,
      );
    }
    final error = pasteImageError(read.bytes);
    if (error != null) {
      if (msg.silentFailure) return (this, null);
      return (
        copyWith(
          outputLines: FaTuiModel._appendOutput(outputLines, _dim(error), true),
        ),
        null,
      );
    }
    // One user paste can fire two probes (the Ctrl+V key event plus the
    // terminal's bracketed paste of the same action): the second identical
    // image inside the dedupe window is the same clipboard state, not a
    // second attach.
    final nowMs = nowFn().millisecondsSinceEpoch;
    final lastBytes = _lastPasteboardImageBytes;
    if (lastBytes != null &&
        nowMs - _lastPasteboardImageAtMs < _pasteboardDedupeWindowMs &&
        _bytesEqual(lastBytes, read.bytes)) {
      return (this, null);
    }
    final mime = sniffImageMime(read.bytes)!;
    final attachment = TuiImageAttachment(
      name: 'clipboard-${attachments.length + 1}.${imageMimeExtension(mime)}',
      mimeType: mime,
      bytes: read.bytes,
    );
    final next = copyWith(attachments: [...attachments, attachment]);
    next._lastPasteboardImageBytes = read.bytes;
    next._lastPasteboardImageAtMs = nowMs;
    return (next, null);
  }

  /// One async pasteboard probe; the outcome lands back as a
  /// [PasteboardResultMsg]. [silentFailure] is set for bracketed-paste
  /// probes (issue #1067) so a plain-text paste never prints errors.
  /// Requires [FaTuiCallbacks.readClipboardImage] to be wired.
  Cmd _pasteboardProbe(bool silentFailure) {
    final reader = callbacks.readClipboardImage!;
    return () async =>
        PasteboardResultMsg(await reader(), silentFailure: silentFailure);
  }

  /// Ctrl+V (issue #276): read the platform pasteboard off the UI loop and
  /// attach the image as a composer chip. Without a wired reader (or in
  /// prompt mode) this is a no-op — the prompt zone owns plain pastes.
  /// Bracketed pastes probe through [_handlePaste] with the same seam
  /// (issue #1067), keeping this keybinding working identically.
  (Model, Cmd?)? _handlePasteImageKey(KeyMsg msg) {
    if (msg.key != 'ctrl+v') return null;
    final reader = callbacks.readClipboardImage;
    if (reader == null) {
      return (
        copyWith(
          outputLines: FaTuiModel._appendOutput(
            outputLines,
            _dim(clipboardUnavailableHint),
            true,
          ),
        ),
        null,
      );
    }
    return (this, _pasteboardProbe(false));
  }
}
