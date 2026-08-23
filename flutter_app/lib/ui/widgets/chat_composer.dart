// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/upload_picker_stub.dart'
    if (dart.library.html) 'package:fa/services/upload_picker_web.dart';

/// The chat composer: attachment chips + staging into the sandbox `uploads/`
/// folder, the streaming/queued-steer indicators, the text field, the
/// voice-input mic button, and the gradient send/stop button.
///
/// The implementation lives in the `fa_ui` package; this adapter keeps the
/// app's original constructor surface (AgentService + the injectable
/// picker/ASR fakes the tests use) and bridges them to the shared widget's
/// host hooks.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.service,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.clipboardImageReader = _readClipboardImage,
    this.leadingBuilder,
    this.hideMicWhenNotEmpty = false,
    this.onSent,
    this.onFocusChanged,
    this.autofocus = true,
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

  /// Clipboard image probe for smart paste (Cmd/Ctrl+V). Defaults to the
  /// super_clipboard-backed reader; tests inject a fake or null.
  final fa_ui.FaClipboardImageReader? clipboardImageReader;

  /// Replaces the built-in attach button in the leading slot (the session
  /// chat bar's sessions-drawer toggle). Null keeps the attach button.
  final Widget Function(BuildContext context)? leadingBuilder;

  /// iMessage-style trailing slot: exactly one action (mic / stop / send),
  /// swapped with a scale+fade as the field content changes.
  final bool hideMicWhenNotEmpty;

  /// Fired after a message was sent successfully.
  final VoidCallback? onSent;

  /// Fired when the input field's focus changes (the session chat sheet
  /// opens its panel on focus).
  final ValueChanged<bool>? onFocusChanged;

  /// Whether the field grabs focus on mount/session switch. The always-
  /// visible launcher bar passes false so the keyboard stays down until
  /// the user actually taps the field.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final picker = uploadPicker ?? createUploadPicker();
    return fa_ui.ChatComposer(
      service: service,
      uploadPicker: picker == null
          ? null
          : () async => [
              for (final file in await picker.pick())
                (
                  name: file.name,
                  bytes: file.bytes,
                  mimeType: mimeTypeForUploadName(file.name),
                ),
            ],
      galleryPicker: () => _pickImage(ImageSource.gallery),
      // macOS has no camera through ImagePicker (it requires a
      // cameraDelegate — only iOS/Android register one). Hide the
      // camera entry on macOS so the picker doesn't throw.
      cameraPicker: (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS)
          ? null
          : () => _pickImage(ImageSource.camera),
      voiceInput: _AsrVoiceInput(
        service: service,
        asr: asr,
        transcriber: asrTranscriber,
      ),
      clipboardImageReader: clipboardImageReader,
      leadingBuilder: leadingBuilder,
      hideMicWhenNotEmpty: hideMicWhenNotEmpty,
      onSent: onSent,
      onFocusChanged: onFocusChanged,
      autofocus: autofocus,
    );
  }

  static Future<List<fa_ui.FaChatUploadFile>> _pickImage(
    ImageSource source,
  ) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return const [];
    final bytes = await picked.readAsBytes();
    return [
      (
        name: picked.name,
        bytes: bytes,
        mimeType: mimeTypeForUploadName(picked.name),
      ),
    ];
  }

  /// Smart paste's image probe (the YoLoIT ClipboardFileService pattern):
  /// reads image bytes off the system pasteboard, null when it holds no
  /// image. Returns a generated name — the composer's staging turns it into
  /// an `uploads/` chip.
  static Future<fa_ui.FaChatUploadFile?> _readClipboardImage() async {
    Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } on Object {
      // Clipboard access is best effort — a failure just means "no image".
    }
    if (bytes == null || bytes.isEmpty) return null;
    final name = 'clipboard-${DateTime.now().millisecondsSinceEpoch}.png';
    return (name: name, bytes: bytes, mimeType: mimeTypeForUploadName(name));
  }
}

/// [fa_ui.FaChatVoiceInput] over the app's [AsrApi] + [AsrTranscriber]
/// stack: the mic capture is platform code, the transcriber is resolved
/// lazily per take through the session's media gateway (the
/// media_models.json `transcription` slot, falling back to the active
/// provider) so slot edits and provider switches are picked up.
final class _AsrVoiceInput implements fa_ui.FaChatVoiceInput {
  _AsrVoiceInput({required this.service, AsrApi? asr, this.transcriber})
    : _asr = asr ?? createAsrService();

  final AgentService service;
  final AsrApi _asr;
  final AsrTranscriber? transcriber;

  @override
  bool get isAvailable => asrPlatformSupported;

  @override
  String? get unavailableReason => null;

  @override
  Future<bool> start() async {
    if (!await _asr.requestAccess()) return false;
    await _asr.startRecording();
    return true;
  }

  @override
  Future<String?> stopAndTranscribe() async {
    final recording = await _asr.stopRecording();
    final transcriber = this.transcriber ?? await _resolveTranscriber();
    if (transcriber == null) throw StateError(asrNoEndpointMessage);
    final bytes = await _asr.readRecording(recording.path);
    final filename = recording.path.split(RegExp(r'[/\\]')).last;
    final transcript = await transcriber.transcribe(
      bytes: bytes,
      filename: filename,
    );
    return transcript.isEmpty ? null : transcript;
  }

  @override
  Future<void> cancel() async {
    try {
      await _asr.stopRecording();
    } on Object {
      // Best effort: a recording nobody reads is harmless.
    }
  }

  /// The transcriber for a finished take: the injected one, or one resolved
  /// through the session's media gateway, falling back to the active
  /// provider's endpoint directly (services built around a pre-constructed
  /// agent — tests — have no gateway). Null means no ASR-capable endpoint
  /// is configured.
  Future<AsrTranscriber?> _resolveTranscriber() async {
    final gateway = service.mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    final config = service.configForClone;
    return whisperTranscriberFor(
      providerKind: service.providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }
}
