// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/upload_picker_stub.dart'
    if (dart.library.html) 'package:fa/services/upload_picker_web.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/file_preview.dart';

/// The chat composer: attachment chips + staging into the sandbox `uploads/`
/// folder, the streaming/queued-steer indicators, the text field, the
/// voice-input mic button, and the gradient send/stop button.
///
/// Extracted from `ChatScreen` so the session chat sheet over the apps
/// launcher uses the exact same composer; the screen delegates to this
/// widget with no visual change. All l10n and colors come from the context.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.service,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
  });

  /// The session this composer sends to.
  final AgentService service;

  /// File chooser behind the attach sheet's "Attach file" entry.
  /// Defaults to the platform picker (`null` off the web → the entry is
  /// hidden); tests inject a fake.
  final UploadPicker? uploadPicker;

  /// Microphone backend for the voice-input button; `null` uses the
  /// platform service ([createAsrService]). Tests inject a fake.
  final AsrApi? asr;

  /// Transcriber for voice input; `null` derives one from the session's
  /// provider config at stop time (an OpenAI-compatible endpoint). Tests
  /// inject a fake.
  final AsrTranscriber? asrTranscriber;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  final _textController = TextEditingController();

  /// Files attached in the composer but not sent yet. They are staged into
  /// the sandbox `uploads/` folder at PICK time (see
  /// [AgentService.stageAttachment]) — attaching never sends anything by
  /// itself; on send the message references the staged [path]s plus the
  /// typed text.
  final List<({String name, String path, Uint8List bytes, String mimeType})>
  _pendingAttachments = [];

  bool _isStreaming = false;

  /// Arbitrary-file picker for the attach sheet's "Attach file" entry;
  /// `null` off the web, which hides the entry.
  late final UploadPicker? _uploadPicker =
      widget.uploadPicker ?? createUploadPicker();

  /// Microphone backend for the composer's voice-input button.
  late final AsrApi _asr = widget.asr ?? createAsrService();

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
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_onServiceChanged);
      _isStreaming = widget.service.isStreaming;
      widget.service.addListener(_onServiceChanged);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_onServiceChanged);
    _textController.removeListener(_onTextChanged);
    _micPulse.dispose();
    if (_micRecording) {
      // Best effort: never leave the native recorder running.
      _asr.stopRecording().ignore();
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

  /// The transcriber for voice input: the injected one, or one resolved
  /// through the session's media gateway (the media_models.json
  /// `transcription` slot, falling back to the active provider). Resolved
  /// lazily per use so slot edits and a provider switch mid-session are
  /// picked up. Null means no ASR-capable endpoint is configured.
  Future<AsrTranscriber?> _resolveTranscriber() async {
    if (widget.asrTranscriber != null) return widget.asrTranscriber;
    final gateway = widget.service.mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    // Services built around a pre-constructed agent (tests) have no
    // gateway: fall back to the active provider's endpoint directly.
    final config = widget.service.configForClone;
    return whisperTranscriberFor(
      providerKind: widget.service.providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }

  /// Mic button tap: idle starts a recording (after the OS permission
  /// prompt), recording stops it and transcribes the take into the input
  /// field.
  Future<void> _toggleMic() async {
    if (_micTranscribing) return;
    if (_micRecording) {
      await _stopMic();
      return;
    }
    try {
      if (!await _asr.requestAccess()) {
        if (mounted) _showSnack(context.l10n.chatMicDenied);
        return;
      }
      await _asr.startRecording();
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatMicError(e.toString()));
      return;
    }
    if (!mounted) return;
    setState(() => _micRecording = true);
    _micPulse.repeat(reverse: true);
  }

  Future<void> _stopMic() async {
    _micPulse.stop();
    final AsrRecording recording;
    try {
      recording = await _asr.stopRecording();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _micRecording = false);
        _showSnack(context.l10n.chatMicError(e.toString()));
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _micRecording = false;
      _micTranscribing = true;
    });
    try {
      final transcriber = await _resolveTranscriber();
      if (!mounted) return;
      if (transcriber == null) {
        _showSnack(context.l10n.chatMicError(asrNoEndpointMessage));
        return;
      }
      final bytes = await _asr.readRecording(recording.path);
      final filename = recording.path.split(RegExp(r'[/\\]')).last;
      final transcript = await transcriber.transcribe(
        bytes: bytes,
        filename: filename,
      );
      if (!mounted || transcript.isEmpty) return;
      final current = _textController.text;
      final spacer = current.isNotEmpty && !current.endsWith(' ') ? ' ' : '';
      _textController.text = '$current$spacer$transcript';
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatMicError(e.toString()));
    } finally {
      if (mounted) setState(() => _micTranscribing = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    await _stagePending(picked.name, bytes);
  }

  /// Stages one picked file into `uploads/` right away and adds a pending
  /// chip for it. Failures surface as a snackbar — nothing is staged and
  /// nothing is sent.
  Future<void> _stagePending(String name, Uint8List bytes) async {
    final clean = sanitizeUploadName(name).split('/').last;
    if (clean.isEmpty) {
      _showSnack(context.l10n.chatAttachNoName(name));
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
      AppAnalytics.instance.uploadAdded(1);
    } on Object catch (e) {
      if (mounted) {
        _showSnack(context.l10n.chatAttachError(e.toString(), clean));
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

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) return;
    final pending = List.of(_pendingAttachments);
    setState(() => _pendingAttachments.clear());
    _textController.clear();
    // Metadata only (never the text, never the files).
    AppAnalytics.instance.messageSent(
      hasAttachments: pending.isNotEmpty,
      textLength: trimmed.length,
    );

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
        // the files with its tools (see AgentService.sendAttachments).
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
    } on Object catch (e) {
      // The send itself failed before the run started: hand the chips and
      // the typed text back so nothing the user composed is lost.
      if (mounted) {
        setState(() => _pendingAttachments.addAll(pending));
        _textController.text = trimmed;
        _showSnack(context.l10n.chatSendError(e.toString()));
      }
    }
  }

  /// Picks arbitrary files and stages them as pending attachments (web
  /// only; elsewhere the picker is `null`). Staging happens immediately —
  /// the chips wait in the composer until the user sends (see [_send]).
  Future<void> _attachFiles() async {
    final picker = _uploadPicker;
    if (picker == null) return;
    final List<UploadFile> picked;
    try {
      picked = await picker.pick();
    } on Object catch (e) {
      if (mounted) _showSnack(context.l10n.chatUploadFailed(e.toString()));
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final sizeError = uploadBatchSizeError(
      picked,
      message: (total, max) => context.l10n.uploadTooLarge(max, total),
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
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(context.l10n.chatGallery),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(context.l10n.chatCamera),
              onTap: () {
                Navigator.of(context).pop();
                _pickImage(ImageSource.camera);
              },
            ),
            if (_uploadPicker != null)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: Text(context.l10n.chatAttachFile),
                onTap: () {
                  Navigator.of(context).pop();
                  _attachFiles();
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
    final palette = FahColors.of(context);
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
            tooltip: context.l10n.chatRemoveAttachment,
            onPressed: () => _removePendingAttachment(index),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = FahColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.border)),
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
                      context.l10n.chatTyping,
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
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: context.l10n.chatAttachTooltip,
                    onPressed: _showAttachmentSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: context.l10n.chatInputHint,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
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
                  if (asrPlatformSupported) _buildMicButton(context),
                  const SizedBox(width: 4),
                  Container(
                    decoration: BoxDecoration(
                      gradient: palette.brandGradient,
                      shape: BoxShape.circle,
                    ),
                    child: Builder(
                      builder: (context) {
                        // Stop only while streaming AND nothing typed; with
                        // text in the field the button is a steer-send
                        // (interrupt the turn and run the message).
                        final showStop =
                            _isStreaming && _textController.text.trim().isEmpty;
                        return IconButton(
                          icon: Icon(
                            showStop ? Icons.stop : Icons.send,
                            size: 20,
                          ),
                          color: palette.onAccent,
                          tooltip: showStop
                              ? context.l10n.chatAbortTooltip
                              : (_isStreaming
                                    ? context.l10n.chatSteerTooltip
                                    : context.l10n.chatSendTooltip),
                          onPressed: showStop
                              ? widget.service.abort
                              : () => _send(_textController.text),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The composer's voice-input button: idle shows a mic (tap to record),
  /// recording pulses red (tap again to stop + transcribe), transcribing
  /// shows a spinner. Rendered only where [asrPlatformSupported].
  Widget _buildMicButton(BuildContext context) {
    final l10n = context.l10n;
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
          tooltip: l10n.chatMicStopTooltip,
          onPressed: _toggleMic,
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.mic_none),
      tooltip: l10n.chatMicTooltip,
      onPressed: _toggleMic,
    );
  }
}
