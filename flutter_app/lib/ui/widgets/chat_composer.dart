// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
      cameraPicker: () => _pickImage(ImageSource.camera),
      voiceInput: _AsrVoiceInput(
        service: service,
        asr: asr,
        transcriber: asrTranscriber,
      ),
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
