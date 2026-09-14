/// The clipboard-paste zone (issue #276) — split out of `fa_tui.dart` to
/// keep it under the repo's 2800-line size gate. Same library (a `part
/// of`), so the extension sees FaTuiModel's private members (`_appendOutput`,
/// `outputLines`, `attachments`).
part of 'fa_tui.dart';

/// The async Ctrl+V pasteboard read landed; carries image bytes or the
/// named failure reason.
final class PasteboardResultMsg extends Msg {
  PasteboardResultMsg(this.read);
  final PasteboardRead read;
}

extension FaTuiPaste on FaTuiModel {
  /// Ctrl+V outcome: image bytes become a composer chip; failures print
  /// their NAMED reason (unavailable pasteboard, size cap, not an image).
  (Model, Cmd?) _handlePasteboardResult(PasteboardResultMsg msg) {
    final read = msg.read;
    if (read is! PasteboardImage) {
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
      return (
        copyWith(
          outputLines: FaTuiModel._appendOutput(outputLines, _dim(error), true),
        ),
        null,
      );
    }
    final mime = sniffImageMime(read.bytes)!;
    final attachment = TuiImageAttachment(
      name: 'clipboard-${attachments.length + 1}.${imageMimeExtension(mime)}',
      mimeType: mime,
      bytes: read.bytes,
    );
    return (copyWith(attachments: [...attachments, attachment]), null);
  }

  /// Ctrl+V (issue #276): read the platform pasteboard off the UI loop and
  /// attach the image as a composer chip. Without a wired reader (or in
  /// prompt mode) this is a no-op — the prompt zone owns plain pastes.
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
    return (
      this,
      () async {
        final read = await reader();
        return PasteboardResultMsg(read);
      },
    );
  }
}
