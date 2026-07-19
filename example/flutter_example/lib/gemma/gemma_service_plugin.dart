// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The real on-device Gemma engine, backed by the `flutter_gemma` plugin
/// (LiteRT-LM `.litertlm` engine). Compiles on IO platforms (FFI engine) and
/// on web (`@litert-lm/core` via `flutter_gemma_litertlm`'s conditional
/// export); desktop builds get `gemma_service_stub.dart` instead. Host tests
/// inject fakes and never touch this implementation.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/services/model_repository.dart'
    as model_repository;
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'gemma_types.dart';
import 'gemma_web_registration.dart';

/// Returns the shared [GemmaService] (the plugin is process-global, so the
/// service is a singleton — the settings form's load and the stream
/// function's first turn reuse the same warm engine).
GemmaEngineApi createGemmaService() => GemmaService.instance;

/// A [GemmaEngineApi] over `FlutterGemma`.
///
/// Lifecycle: [installModel] downloads the `.litertlm` bundle and marks it
/// active (idempotent — already-installed models skip the download and are
/// just re-activated, which is also how E2B↔E4B switching works);
/// [loadModel] creates the in-memory [InferenceModel]; [chatStream] opens a
/// fresh `openChat` per turn.
///
/// Web specifics: web downloads the preset's `-web.litertlm` build
/// ([GemmaModelPreset.webUrl]) — the mobile build's section layout crashes
/// `@litert-lm/core` ("Streaming kTfLiteEmbedder models is not supported
/// yet"). The plugin is initialized with `WebStorageMode.streaming`, so the
/// download streams into the browser's OPFS storage (Gemma 4 E2B/E4B exceed
/// Chrome's ~2 GB single-blob limit) and the `@litert-lm/core` engine
/// consumes it as a `ReadableStream`. The plugin's web URL registry is
/// in-memory only, so [loadModel] re-runs the idempotent install on web:
/// after a page reload this re-registers the `opfs://` source from the OPFS
/// cache without a download (and without the HuggingFace token, which is
/// never persisted).
final class GemmaService implements GemmaEngineApi {
  GemmaService._();

  /// The process-wide shared instance.
  static final GemmaService instance = GemmaService._();

  var _initialized = false;
  InferenceModel? _model;
  GemmaModelPreset? _loadedPreset;
  InferenceChat? _activeChat;
  final _progress = StreamController<GemmaProgress>.broadcast();

  @override
  bool get isAvailable => gemmaProviderSupported;

  @override
  String? get loadedModelId => _loadedPreset?.id;

  @override
  Stream<GemmaProgress> get progressEvents => _progress.stream;

  /// Registers the LiteRT-LM engine once per process. The HF token is NOT
  /// set here — it is passed per-download via `fromNetwork(token:)` so a
  /// token entered (or changed) in the settings form takes effect without
  /// re-initializing the plugin.
  ///
  /// `WebStorageMode.streaming` only affects web (ignored on mobile): it
  /// puts model storage in OPFS with `ReadableStream` loading, the only
  /// mode that clears Chrome's ~2 GB blob-fetch limit for Gemma 4.
  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // Web only (no-op elsewhere): dart2js release builds tree-shake the
    // plugin registrant's platform-instance assignment out, which would
    // dead-code the whole web engine — see gemma_web_registration.dart.
    ensureGemmaWebRegistered();
    await FlutterGemma.initialize(
      inferenceEngines: const [LiteRtLmEngine()],
      webStorageMode: WebStorageMode.streaming,
    );
    _initialized = true;
  }

  void _requireAvailable() {
    if (!isAvailable) throw StateError(gemmaUnsupportedPlatformMessage);
  }

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async {
    _requireAvailable();
    await _ensureInitialized();
    return FlutterGemma.isModelInstalled(preset.filenameFor(isWeb: kIsWeb));
  }

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {
    _requireAvailable();
    await _ensureInitialized();
    final token = huggingFaceToken == null || huggingFaceToken.isEmpty
        ? null
        : huggingFaceToken;
    // install() is idempotent: with the bundle already on disk it skips the
    // download and only re-marks the model active. That makes it double as
    // the model-switch path when both presets are installed. The plugin
    // keys the install under the URL's basename — on web that is the
    // distinct `-web.litertlm` name, so a stale mobile-named OPFS entry is
    // never mistaken for this install.
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(preset.urlFor(isWeb: kIsWeb), token: token).withProgress((
      progress,
    ) {
      _progress.add(
        GemmaProgress(
          fraction: progress / 100,
          text: 'Downloading ${preset.displayName}… $progress%',
        ),
      );
    }).install();
    _progress.add(
      GemmaProgress(fraction: 1, text: '${preset.displayName} installed'),
    );
  }

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {
    _requireAvailable();
    await _ensureInitialized();
    if (_loadedPreset?.id == preset.id && _model != null) return;
    if (kIsWeb) {
      // The plugin's web URL registry is in-memory: after a page reload the
      // `opfs://` registration is gone and `getActiveModel` would fall back
      // to the raw https URL, making the engine re-download the weights.
      // The idempotent install re-registers the OPFS stream from the
      // browser's cache (no download, no token needed) and re-marks the
      // model active. On mobile the active identity + files survive a
      // restart natively, so this stays web-only.
      await installModel(preset);
    }
    final previous = _model;
    _model = null;
    _loadedPreset = null;
    if (previous != null) await previous.close();
    _progress.add(const GemmaProgress(text: 'Loading model into memory…'));
    _model = await FlutterGemma.getActiveModel(
      maxTokens: preset.contextWindow,
      preferredBackend: PreferredBackend.gpu,
    );
    _loadedPreset = preset;
  }

  @override
  Future<void> chatStream({
    required List<GemmaChatMessage> messages,
    required void Function(String chunk) onChunk,
    String? systemInstruction,
    void Function()? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxOutputTokens,
  }) async {
    final model = _model;
    final preset = _loadedPreset;
    if (model == null || preset == null) {
      throw StateError(
        'No Gemma model is loaded. Install and load one from the settings '
        'form first.',
      );
    }
    // openChat (not createChat): it forwards `tools` to the session, which
    // for ModelType.gemma4 becomes the SDK-native tools_json conversation
    // config — createChat drops them (verified against flutter_gemma
    // 1.3.1). Each turn gets a fresh chat; the harness owns conversation
    // history, so the full context is replayed below on every call. That
    // keeps compaction/rewrite semantics exact at the cost of re-prefill.
    final chat = await model.openChat(
      temperature: preset.temperature,
      topK: preset.topK,
      topP: preset.topP,
      systemInstruction: systemInstruction,
      tools: [
        for (final tool in tools ?? const <Map<String, dynamic>>[])
          _toPluginTool(tool),
      ],
      supportsFunctionCalls: tools != null && tools.isNotEmpty,
      modelType: ModelType.gemma4,
      maxOutputTokens: maxOutputTokens,
    );
    _activeChat = chat;
    try {
      for (final message in messages) {
        await chat.addQueryChunk(_toPluginMessage(message));
      }
      // The plugin surfaces Gemma 4 tool calls complete (SDK-parsed) at
      // end-of-stream; accumulate them and emit one OpenAI-shaped payload.
      final calls = <Map<String, dynamic>>[];
      await for (final response in chat.generateChatResponseAsync()) {
        switch (response) {
          case TextResponse(:final token):
            if (token.isNotEmpty) onChunk(token);
          case FunctionCallResponse(:final name, :final args):
            calls.add({'name': name, 'args': args});
          case ParallelFunctionCallResponse(calls: final batch):
            for (final call in batch) {
              calls.add({'name': call.name, 'args': call.args});
            }
          case ThinkingResponse():
            // Thinking is disabled (isThinking: false); drop defensively.
            break;
        }
      }
      if (calls.isNotEmpty) {
        onToolCalls?.call(
          jsonEncode([
            for (var i = 0; i < calls.length; i++)
              {
                'index': i,
                'type': 'function',
                'function': {
                  'name': calls[i]['name'],
                  'arguments': jsonEncode(calls[i]['args']),
                },
              },
          ]),
        );
      }
      onDone?.call();
    } catch (error) {
      onError?.call(error.toString());
    } finally {
      _activeChat = null;
      unawaited(chat.close());
    }
  }

  @override
  Future<void> interrupt() async {
    try {
      await _activeChat?.stopGeneration();
    } on Object {
      // Best effort: a failed stop must not break the abort path.
    }
  }

  @override
  Future<void> unload() async {
    final model = _model;
    _model = null;
    _loadedPreset = null;
    if (model != null) await model.close();
  }

  @override
  Future<List<GemmaInstalledModel>> installedModels() async {
    _requireAvailable();
    await _ensureInitialized();
    final repository = ServiceRegistry.instance.modelRepository;
    return [
      for (final model in await repository.listInstalled())
        if (model.type == model_repository.ModelType.inference)
          GemmaInstalledModel(filename: model.id, sizeBytes: model.sizeBytes),
    ];
  }

  @override
  Future<void> uninstall(String filename) async {
    _requireAvailable();
    await _ensureInitialized();
    // Deleting the loaded/active model: close it and clear the plugin's
    // persisted active identity first, so a later getActiveModel cannot
    // resurrect a spec whose files are gone. On web after a page reload
    // `_loadedPreset` is null but the persisted identity survives, hence
    // the manager check in addition to the in-memory one.
    final loaded = _loadedPreset;
    if (loaded != null && loaded.filenameFor(isWeb: kIsWeb) == filename) {
      await unload();
    }
    final manager = FlutterGemmaPlugin.instance.modelManager;
    await manager.ensureInitialized();
    if (manager.activeInferenceModel?.name == _baseName(filename)) {
      await FlutterGemma.clearActiveInferenceIdentity();
    }
    await FlutterGemma.uninstallModel(filename);
  }

  /// The plugin's active-spec name for [filename] — the file name minus its
  /// extension (mirrors the installer's `FileNameUtils.getBaseName`).
  static String _baseName(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot == -1 ? filename : filename.substring(0, dot);
  }

  /// Maps a serialized OpenAI tool entry to the plugin's [Tool].
  static Tool _toPluginTool(Map<String, dynamic> tool) {
    final function = tool['function'];
    if (function is! Map<String, dynamic>) {
      throw StateError('Malformed tool entry: $tool');
    }
    return Tool(
      name: function['name'] as String? ?? '',
      description: function['description'] as String? ?? '',
      parameters:
          (function['parameters'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  /// Maps a provider-neutral [GemmaChatMessage] to the plugin's [Message].
  /// Tool results go through [Message.toolResponse], which the plugin
  /// renders as a `<tool_response>` block; historical assistant tool calls
  /// replay as `Message.toolCall` carrying the OpenAI-style assistant JSON
  /// (the shape the plugin's own history replay stores).
  static Message _toPluginMessage(GemmaChatMessage message) {
    return switch (message.role) {
      'assistant' => Message.text(text: message.content, isUser: false),
      'tool_call' => Message.toolCall(text: message.content),
      'tool_result' => Message.toolResponse(
        toolName: message.toolName ?? 'tool',
        response: {'output': message.content},
      ),
      _ => Message.text(text: message.content, isUser: true),
    };
  }
}
