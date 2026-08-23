// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'chat_strings.dart';
import 'fa_chat_features.dart';
import 'fa_chat_host.dart';
import 'fa_chat_service.dart';
import 'fa_glyphs.dart';
import 'upload_utils.dart';

/// The chat composer: attachment chips + staging into the sandbox `uploads/`
/// folder, the streaming/queued-steer indicators, the text field, the
/// voice-input mic button, and the gradient send/stop button.
///
/// Backend-agnostic: sends through [FaChatService], picks files/images
/// through [FaChatHost] hooks (or the constructor overrides, which tests
/// inject), and reports analytics through [FaChatHost.track]. All strings
/// come from [FaChatStrings], all colors from the ambient theme.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.service,
    this.features = const FaChatFeatures(),
    this.uploadPicker,
    this.galleryPicker,
    this.cameraPicker,
    this.voiceInput,
    this.clipboardImageReader,
    this.leadingBuilder,
    this.hideMicWhenNotEmpty = false,
    this.onSent,
    this.onFocusChanged,
    this.autofocus = true,
  });

  /// The session this composer sends to.
  final FaChatService service;

  /// Capability flags; the defaults turn everything on and let the host
  /// hooks decide what is actually reachable.
  final FaChatFeatures features;

  /// Arbitrary-file picker behind the attach sheet's "Attach file" entry;
  /// overrides [FaChatHost.uploadPicker]. Null (with no host hook) hides
  /// the entry.
  final FaChatUploadPicker? uploadPicker;

  /// Gallery picker behind the attach sheet's "Gallery" entry; overrides
  /// [FaChatHost.galleryPicker]. Null (with no host hook) hides the entry.
  final FaChatUploadPicker? galleryPicker;

  /// Camera picker behind the attach sheet's "Camera" entry; overrides
  /// [FaChatHost.cameraPicker]. Null (with no host hook) hides the entry.
  final FaChatUploadPicker? cameraPicker;

  /// Voice-input backend for the mic button; overrides
  /// [FaChatHost.voiceInput]. Null (with no host hook) hides the mic.
  final FaChatVoiceInput? voiceInput;

  /// Clipboard image reader for smart paste; overrides
  /// [FaChatHost.clipboardImageReader]. Null (with no host hook) pastes
  /// text only.
  final FaClipboardImageReader? clipboardImageReader;

  /// Replaces the built-in attach button in the leading slot (e.g. the
  /// launcher's sessions-drawer toggle). Null keeps the default attach
  /// button (shown when a picker is wired).
  final Widget Function(BuildContext context)? leadingBuilder;

  /// iMessage-style trailing slot with exactly ONE action: the mic while
  /// the field is empty and idle, stop while streaming with an empty field,
  /// send as soon as the field has text (the swap runs through an
  /// [AnimatedSwitcher] — a quick scale+fade). Default false keeps the mic
  /// and the send/stop button both always visible (full chat screen
  /// behavior).
  final bool hideMicWhenNotEmpty;

  /// Fired after a message was sent successfully (the launcher's bar uses
  /// it to open the session panel).
  final VoidCallback? onSent;

  /// Fired when the input field's focus changes (the launcher's bar opens
  /// the session panel the moment the user starts typing).
  final ValueChanged<bool>? onFocusChanged;

  /// Whether the field grabs focus on mount and on session switch (the
  /// full chat screen wants that; the launcher's always-visible bar must
  /// NOT pop the keyboard at app start). Default true.
  final bool autofocus;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();

  /// Files attached in the composer but not sent yet. They are staged into
  /// the sandbox `uploads/` folder at PICK time (see
  /// [FaChatService.stageAttachment]) — attaching never sends anything by
  /// itself; on send the message references the staged [path]s plus the
  /// typed text.
  final List<({String name, String path, Uint8List bytes, String mimeType})>
  _pendingAttachments = [];

  bool _isStreaming = false;

  /// Pickers resolved once (constructor override, else the host hook), in
  /// the order the attach sheet lists them.
  late final FaChatUploadPicker? _galleryPicker =
      widget.galleryPicker ?? FaChatHost.galleryPicker;
  late final FaChatUploadPicker? _cameraPicker =
      widget.cameraPicker ?? FaChatHost.cameraPicker;
  late final FaChatUploadPicker? _uploadPicker =
      widget.uploadPicker ?? FaChatHost.uploadPicker;

  /// Voice-input backend for the composer's mic button.
  late final FaChatVoiceInput? _voiceInput =
      widget.voiceInput ?? FaChatHost.voiceInput;

  /// Clipboard image reader for smart paste (Cmd/Ctrl+V).
  late final FaClipboardImageReader? _clipboardImageReader =
      widget.clipboardImageReader ?? FaChatHost.clipboardImageReader;

  /// Voice-input state: idle → recording → transcribing → idle.
  bool _micRecording = false;
  bool _micTranscribing = false;

  /// Drives the red pulse of the recording-state mic button; runs only
  /// while recording (a repeating animation would keep `pumpAndSettle`
  /// from ever settling if left running). Created in [initState] — a
  /// `late` field touched first in [dispose] would create a ticker while
  /// the element is deactivating.
  late final AnimationController _micPulse;

  @override
  void initState() {
    super.initState();
    _micPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _isStreaming = widget.service.isStreaming;
    widget.service.addListener(_onServiceChanged);
    // The send/stop button's look depends on the field being non-empty.
    _textController.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChange);
    // Auto-focus the input when a session opens (first mount or switch).
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_onServiceChanged);
      _isStreaming = widget.service.isStreaming;
      widget.service.addListener(_onServiceChanged);
      // Session switched — focus the input so the user can type immediately.
      if (widget.autofocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    widget.service.removeListener(_onServiceChanged);
    _textController.removeListener(_onTextChanged);
    _micPulse.dispose();
    if (_micRecording) {
      // Best effort: never leave the native recorder running.
      _voiceInput?.cancel().ignore();
    }
    _textController.dispose();
    super.dispose();
  }

  /// Streaming flag + queued-steer rows live on the service; rebuild on any
  /// change (the composer subtree is small).
  void _onServiceChanged() {
    if (!mounted) return;
    setState(() => _isStreaming = widget.service.isStreaming);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChange() {
    widget.onFocusChanged?.call(_focusNode.hasFocus);
  }

  /// Mic button tap: idle starts a recording (after the OS permission
  /// prompt), recording stops it and transcribes the take into the input
  /// field.
  Future<void> _toggleMic() async {
    final voiceInput = _voiceInput;
    if (voiceInput == null || _micTranscribing) return;
    if (_micRecording) {
      await _stopMic(voiceInput);
      return;
    }
    final strings = FaChatStrings.of(context);
    final bool started;
    try {
      started = await voiceInput.start();
    } on Object catch (e) {
      if (mounted) _showSnack(strings.chatMicError(e.toString()));
      return;
    }
    if (!started) {
      if (mounted) {
        _showSnack(voiceInput.unavailableReason ?? strings.chatMicDenied);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _micRecording = true);
    _micPulse.repeat(reverse: true);
  }

  Future<void> _stopMic(FaChatVoiceInput voiceInput) async {
    _micPulse.stop();
    if (!mounted) return;
    setState(() {
      _micRecording = false;
      _micTranscribing = true;
    });
    try {
      final transcript = await voiceInput.stopAndTranscribe();
      if (!mounted || transcript == null || transcript.isEmpty) return;
      final current = _textController.text;
      final spacer = current.isNotEmpty && !current.endsWith(' ') ? ' ' : '';
      _textController.text = '$current$spacer$transcript';
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
      FaChatHost.track('voice_input_used');
    } on Object catch (e) {
      if (mounted) {
        _showSnack(
          FaChatStrings.of(
            context,
          ).chatMicError(e is StateError ? e.message : e.toString()),
        );
      }
    } finally {
      if (mounted) setState(() => _micTranscribing = false);
    }
  }

  /// Stages one picked file into `uploads/` right away and adds a pending
  /// chip for it. Failures surface as a snackbar — nothing is staged and
  /// nothing is sent.
  Future<void> _stagePending(String name, Uint8List bytes) async {
    final strings = FaChatStrings.of(context);
    final clean = sanitizeUploadName(name).split('/').last;
    if (clean.isEmpty) {
      _showSnack(strings.chatAttachNoName(name));
      return;
    }
    try {
      final path = await widget.service.stageAttachment(
        name: clean,
        bytes: bytes,
      );
      if (!mounted) return;
      setState(() {
        _pendingAttachments.add((
          name: clean,
          path: path,
          bytes: bytes,
          mimeType: mimeTypeForUploadName(clean),
        ));
      });
      FaChatHost.track('upload_added', {'count': 1});
    } on Object catch (e) {
      if (mounted) {
        _showSnack(strings.chatAttachError(e.toString(), clean));
      }
    }
  }

  void _removePendingAttachment(int index) {
    final removed = _pendingAttachments[index];
    setState(() => _pendingAttachments.removeAt(index));
    // The file was staged at pick time; removing the chip drops it again
    // (best effort — a leftover in uploads/ is harmless).
    unawaited(widget.service.discardStagedAttachment(removed.path));
  }

  /// Shift+Enter inserts a newline instead of sending. The key event is
  /// handled here (a Focus ancestor) so the macOS/Windows/Linux text-input
  /// plugin never sees it — left alone it treats Enter-with-modifiers as the
  /// `send` action. Bare Enter still flows to the IME and sends.
  ///
  /// Cmd/Ctrl+V is smart paste (the YoLoIT pattern): a clipboard image is
  /// staged as an upload chip, long or multi-line text becomes a staged
  /// `.txt` chip, and only short single-line text is pasted inline.
  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isShiftPressed) {
      _insertTextAtSelection('\n');
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      unawaited(_handleSmartPaste());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Smart paste: clipboard image → staged upload chip; long/multi-line
  /// text → staged `.txt` chip; short single-line text → inserted inline at
  /// the cursor. Mirrors YoLoIT's SmartClipboardPasteService, except staged
  /// content lands in the sandbox `uploads/` as an attachment chip instead
  /// of a pasted temp-file path.
  Future<void> _handleSmartPaste() async {
    final imageReader = _clipboardImageReader;
    if (imageReader != null) {
      try {
        final image = await imageReader();
        if (image != null) {
          if (mounted) await _stagePending(image.name, image.bytes);
          return;
        }
      } on Object {
        // Clipboard probing is best effort — fall through to text.
      }
    }
    String? text;
    try {
      text = (await Clipboard.getData('text/plain'))?.text;
    } on Object {
      // No clipboard access (web denial) — nothing to paste.
    }
    if (text == null || text.isEmpty || !mounted) return;
    if (_isSafeInlinePaste(text) || _looksLikeUrl(text)) {
      _insertTextAtSelection(text);
    } else {
      await _stagePending(
        'pasted-${DateTime.now().millisecondsSinceEpoch}.txt',
        Uint8List.fromList(utf8.encode(text)),
      );
    }
  }

  /// Short, single-line, control-character-free text pastes inline;
  /// anything longer or multi-line becomes a staged file chip.
  static bool _isSafeInlinePaste(String text) {
    if (text.length > 1000) return false;
    if (text.contains('\n') || text.contains('\r')) return false;
    for (final codeUnit in text.codeUnits) {
      if (codeUnit < 32 && codeUnit != 9) return false;
    }
    return true;
  }

  /// Single-line URLs paste inline, never as a file chip.
  static bool _looksLikeUrl(String text) {
    final trimmed = text.trim();
    if (trimmed.contains('\n') || trimmed.contains('\r')) return false;
    final lower = trimmed.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('file://');
  }

  void _insertTextAtSelection(String insert) {
    final value = _textController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _textController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) return;
    // The IME's send action UNFOCUSES the field (EditableText finalizes
    // editing with shouldUnfocus for send/done/go/search). A chat composer
    // keeps the keyboard up instead — the follow-up message must not need a
    // re-tap. Defer past performAction's own unfocus (end of this frame).
    final restoreFocus = _focusNode.hasFocus;
    if (restoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    final pending = List.of(_pendingAttachments);
    setState(() => _pendingAttachments.clear());
    _textController.clear();
    // Metadata only (never the text, never the files).
    FaChatHost.track('message_sent', {
      'has_attachments': pending.isNotEmpty,
      'text_length': trimmed.length,
    });

    try {
      // Capture the pre-send streaming state: sendText STARTS a run when
      // idle, which flips the flag synchronously — aborting on the flipped
      // flag would kill the run we just started (that's the "empty session
      // after every send" bug). The interrupt is only for a run that was
      // ALREADY in flight when the user hit send.
      final wasStreaming = _isStreaming;
      if (pending.isEmpty) {
        await widget.service.sendText(trimmed);
      } else {
        // Attachments were staged into <cwd>/uploads/ at pick time; the
        // outgoing message references the sandbox paths so the agent reads
        // the files with its tools (see FaChatService.sendAttachments).
        await widget.service.sendAttachments(
          attachments: [
            for (final attachment in pending)
              (
                path: attachment.path,
                bytes: attachment.bytes,
                mimeType: attachment.mimeType,
              ),
          ],
          text: trimmed,
        );
      }
      // Steer-interrupt (pi semantics): a message sent mid-run interrupts
      // the current turn — the queued message gets its own run right after
      // the lifecycle ends (AgentEndEvent → continueRun), instead of
      // waiting out a long turn.
      if (wasStreaming) widget.service.abort();
      widget.onSent?.call();
    } on Object catch (e) {
      // The send itself failed before the run started: hand the chips and
      // the typed text back so nothing the user composed is lost.
      if (mounted) {
        setState(() => _pendingAttachments.addAll(pending));
        _textController.text = trimmed;
        _showSnack(FaChatStrings.of(context).chatSendError(e.toString()));
      }
    }
  }

  /// Picks arbitrary files and stages them as pending attachments. Staging
  /// happens immediately — the chips wait in the composer until the user
  /// sends (see [_send]).
  Future<void> _attachFiles(FaChatUploadPicker picker) async {
    final List<FaChatUploadFile> picked;
    try {
      picked = await picker();
    } on Object catch (e) {
      if (mounted) {
        _showSnack(FaChatStrings.of(context).chatUploadFailed(e.toString()));
      }
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final sizeError = uploadBatchSizeError(
      [for (final file in picked) (name: file.name, bytes: file.bytes)],
      message: (total, max) =>
          FaChatStrings.of(context).uploadTooLarge(max, total),
    );
    if (sizeError != null) {
      _showSnack(sizeError);
      return;
    }

    for (final file in picked) {
      await _stagePending(file.name, file.bytes);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  void _showAttachmentSheet() {
    final strings = FaChatStrings.of(context);
    final galleryPicker = _galleryPicker;
    final cameraPicker = _cameraPicker;
    final uploadPicker = _uploadPicker;

    // Skip the sheet when there's only one option — go straight to the
    // picker (e.g. on macOS the camera is hidden, leaving gallery +
    // file; if only one is wired up there's no choice to make).
    final available = <(IconData, String, FaChatUploadPicker)>[
      if (galleryPicker != null)
        (Icons.photo_library, strings.chatGallery, galleryPicker),
      if (cameraPicker != null)
        (Icons.camera_alt, strings.chatCamera, cameraPicker),
      if (uploadPicker != null)
        (Icons.upload_file, strings.chatAttachFile, uploadPicker),
    ];
    if (available.length == 1) {
      _attachFiles(available.single.$3);
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (icon, label, picker) in available)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () {
                  Navigator.of(context).pop();
                  _attachFiles(picker);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// One pending attachment in the composer: a thumbnail for decodable
  /// raster images, an icon + name + size chip otherwise (SVG previews stay
  /// generic — see [isInlineImageMimeType]), each with a remove affordance.
  Widget _buildPendingAttachmentChip(int index) {
    final attachment = _pendingAttachments[index];
    final isImage = isInlineImageMimeType(attachment.mimeType);
    final palette = fahChatColorsOf(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.panel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                attachment.bytes,
                height: 48,
                width: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.broken_image_outlined, size: 24),
              ),
            )
          else ...[
            const Icon(Icons.insert_drive_file_outlined, size: 18),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                '${attachment.name.split('/').last} · '
                '${formatFileSize(attachment.bytes.length)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: FaChatStrings.of(context).chatRemoveAttachment,
            onPressed: () => _removePendingAttachment(index),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Chat-surface palette: the host's FaUiTheme background/surface tokens
    // re-seat the strip on the host palette; stock hosts get FahPalette.
    final palette = fahChatColorsOf(context);
    final strings = FaChatStrings.of(context);
    final showAttach =
        widget.features.attachments &&
        (_galleryPicker != null ||
            _cameraPicker != null ||
            _uploadPicker != null);
    final showMic =
        widget.features.voiceInput &&
        _voiceInput != null &&
        _voiceInput.isAvailable;
    // iMessage-style trailing slot: exactly one action — the mic while the
    // field is empty and idle, stop while streaming with an empty field,
    // send as soon as the field has text. A recording/transcribing mic
    // never disappears mid-take. Default mode keeps both always visible.
    final hasText = _textController.text.trim().isNotEmpty;
    final micBusy = _micRecording || _micTranscribing;
    final showSendStop =
        !widget.hideMicWhenNotEmpty ||
        hasText ||
        (!micBusy && (_isStreaming || !showMic));
    final micVisible =
        showMic &&
        (!widget.hideMicWhenNotEmpty || micBusy || (!hasText && !_isStreaming));

    return Container(
      decoration: BoxDecoration(
        // Keep the composer transparent so it inherits the scaffold/sheet
        // surface underneath. This avoids a color mismatch in the iOS/macOS
        // overlay/bottom-sheet where the panel background is panelAlt, not
        // palette.bg.
        // The top hairline still visually separates it from the transcript.
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingAttachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _pendingAttachments.length; i++)
                        _buildPendingAttachmentChip(i),
                    ],
                  ),
                ),
              ),
            if (_isStreaming)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.chatTyping,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.dim,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.service.pendingSteerTexts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final pending in widget.service.pendingSteerTexts)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: palette.userBubble.withValues(alpha: 0.6),
                          border: Border.all(color: palette.userBubbleBorder),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                pending,
                                style: theme.textTheme.bodyMedium,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.schedule, size: 16, color: palette.dim),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              // The one-action slot mode gives the row more air: wider
              // margins plus gaps between the buttons and the field.
              padding: widget.hideMicWhenNotEmpty
                  ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
                  : const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  if (widget.leadingBuilder != null)
                    widget.leadingBuilder!(context)
                  else if (showAttach)
                    IconButton(
                      // The modern "add content" mark: a rounded plus in a
                      // hairline circle (see [FaAttachGlyph]) — rhymes with
                      // the mic circle in the one-action slot.
                      icon: FaAttachGlyph(color: palette.dim),
                      tooltip: strings.chatAttachTooltip,
                      onPressed: _showAttachmentSheet,
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.hideMicWhenNotEmpty ? 6 : 0,
                      ),
                      child: Focus(
                        onKeyEvent: _handleComposerKey,
                        child: TextField(
                          controller: _textController,
                          focusNode: _focusNode,
                          decoration: InputDecoration(
                            hintText: 'Ask anything…',
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            border: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(24),
                              ),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(24),
                              ),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: const OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(24),
                              ),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                          ),
                          maxLines: 5,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: _send,
                        ),
                      ),
                    ),
                  ),
                  if (widget.hideMicWhenNotEmpty)
                    // One-action slot: mic ↔ send/stop swap with a quick
                    // scale+fade instead of a hard cut.
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      ),
                      child: micVisible
                          ? KeyedSubtree(
                              key: const ValueKey('composerTrailingMic'),
                              child: _buildMicButton(context),
                            )
                          : showSendStop
                          ? KeyedSubtree(
                              key: const ValueKey('composerTrailingSend'),
                              child: _buildSendStopButton(palette, strings),
                            )
                          : const SizedBox(
                              key: ValueKey('composerTrailingNone'),
                            ),
                    )
                  else ...[
                    if (micVisible) _buildMicButton(context),
                    if (micVisible && showSendStop) const SizedBox(width: 4),
                    if (showSendStop) _buildSendStopButton(palette, strings),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The circular send/stop button: stop while streaming with an empty
  /// field, send (or steer-send mid-stream) otherwise. Light theme paints
  /// a solid indigo circle; dark theme the brand gradient.
  Widget _buildSendStopButton(FahColors palette, FaChatStrings strings) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.light
            ? palette.indigo
            : null,
        gradient: Theme.of(context).brightness == Brightness.dark
            ? palette.brandGradient
            : null,
        shape: BoxShape.circle,
      ),
      child: Builder(
        builder: (context) {
          // Stop only while streaming AND nothing typed; with text in the
          // field the button is a steer-send (interrupt the turn and run
          // the message).
          final showStop = _isStreaming && _textController.text.trim().isEmpty;
          return IconButton(
            icon: Icon(
              // Prototype uses an up-arrow (send-up) icon.
              showStop ? Icons.stop : Icons.arrow_upward,
              size: 20,
            ),
            color: palette.onAccent,
            tooltip: showStop
                ? strings.chatAbortTooltip
                : (_isStreaming
                      ? strings.chatSteerTooltip
                      : strings.chatSendTooltip),
            onPressed: showStop
                ? widget.service.abort
                : () => _send(_textController.text),
          );
        },
      ),
    );
  }

  /// The composer's voice-input button: idle shows a mic (tap to record),
  /// recording pulses red (tap again to stop + transcribe), transcribing
  /// shows a spinner. Rendered only when the host's voice-input hook
  /// reports itself available.
  Widget _buildMicButton(BuildContext context) {
    final strings = FaChatStrings.of(context);
    if (_micTranscribing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_micRecording) {
      final error = Theme.of(context).colorScheme.error;
      return AnimatedBuilder(
        animation: _micPulse,
        builder: (context, child) => IconButton(
          icon: Icon(
            Icons.mic,
            color: Color.lerp(
              error,
              error.withValues(alpha: 0.35),
              _micPulse.value,
            ),
          ),
          tooltip: strings.chatMicStopTooltip,
          onPressed: _toggleMic,
        ),
      );
    }
    final idle = IconButton(
      icon: Icon(
        Icons.mic_none,
        // Match the send/stop circle's icon size in the one-action slot.
        size: widget.hideMicWhenNotEmpty ? 20 : null,
      ),
      tooltip: strings.chatMicTooltip,
      onPressed: _toggleMic,
    );
    if (!widget.hideMicWhenNotEmpty) return idle;
    // iMessage-style slot: the idle mic sits in the same 48px circle the
    // send button occupies, filled with the text field's pill color plus a
    // hairline border so the two states of the slot read as one control.
    final palette = fahChatColorsOf(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.panelAlt,
        border: Border.all(color: palette.border),
        shape: BoxShape.circle,
      ),
      child: idle,
    );
  }
}
