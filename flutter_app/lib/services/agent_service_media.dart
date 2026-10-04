// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Media surface of [AgentService]: the gateway/video-reader accessors
/// behind the `jsr.fa.media.*` bridges, the ASR transcriber
/// resolution, and the plain-image send path. The [FaChatService]
/// attachment overrides and the private gateway fields stay on the
/// class; notifications route through `_notify()` (`notifyListeners`
/// is @protected, callable only inside the class).
extension AgentServiceMedia on AgentService {
  /// Whether the active provider accepts inline image content: hosted
  /// providers do; the on-device text-only backends (WebLLM, Gemma,
  /// transformers.js) get file paths only, never [ImageContent].
  bool get inlinesImageAttachments =>
      !AgentService._isOnDeviceKind(providerKind);

  /// Media generation gateway shared by the `generate_image` / `speak` /
  /// `generate_music` / `generate_video` tools and exposed for the
  /// `jsr.fa.media.*` bridge.
  /// `null` for services constructed around a pre-constructed [Agent]
  /// (tests).
  MediaGateway? get mediaGateway => _mediaGateway;

  /// Video reader behind the `read_video` tool, exposed for the
  /// `jsr.fa.media.readVideo` bridge. `null` for services constructed
  /// around a pre-constructed [Agent] (tests).
  VideoReader? get videoReader => _videoReader;

  /// Derives the ASR transcriber for jsr bridges (the media_models.json
  /// `transcription` slot, falling back to the active provider); null when
  /// no ASR-capable (OpenAI-compatible) endpoint is configured — the bridge
  /// then answers with an actionable error. Shared by the app view and the
  /// dynamic-message widgets (issue #102 AC6).
  Future<AsrTranscriber?> resolveAsrTranscriber() async {
    final gateway = _mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    final config = _config;
    return whisperTranscriberFor(
      providerKind: _providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }

  /// Sends a user message with an attached image.
  Future<void> sendImage({
    required Uint8List bytes,
    required String mimeType,
    String text = '',
  }) async {
    _clearError();
    final rowProblem = _liveConnectionRowProblem();
    if (rowProblem != null) {
      error = rowProblem;
      _notify();
      return;
    }
    final content = <ContentBlock>[
      if (text.isNotEmpty) TextContent(text: text),
      ImageContent(data: base64Encode(bytes), mimeType: mimeType),
    ];
    final message = UserMessage(content: content, timestamp: DateTime.now());
    if (_agent.state.isStreaming) {
      _agent.steer(message);
      pendingSteerTexts.add(text.isEmpty ? '[image]' : text);
      _notify();
      return;
    }
    _runWithTimeout(() => _agent.promptMessage(message));
  }
}
