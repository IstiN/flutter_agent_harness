// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation of [WebLlmEngineApi] over `@mlc-ai/web-llm`.
///
/// Adapted from the flutter_agent_memory demo's `WebLlmService`: one
/// `MLCEngine` singleton per page, model weights load via `engine.reload`
/// (downloaded into the browser CacheStorage on first use), streaming via
/// the `webllmStreamWithCallbacks` JS helper, cancellation via
/// `interruptGenerate` plus the iterator cancel function.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import 'webllm_js_interop.dart';
import 'webllm_types.dart';

/// Returns the process-wide [WebLlmEngineApi] singleton.
///
/// The engine (and its downloaded weights) is shared between the settings
/// form (which pre-loads the model with a progress bar) and the
/// [AgentService] stream function, so the model picked at connect time is
/// the one already warm.
WebLlmEngineApi createWebLlmService() => _instance ??= WebLlmService._();

WebLlmService? _instance;

/// Owns the `MLCEngine` singleton and the selected model.
final class WebLlmService implements WebLlmEngineApi {
  WebLlmService._();

  WebLlmEngine? _engine;

  @override
  String? loadedModelId;

  final _progressController = StreamController<WebLlmProgress>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<WebLlmProgress> get progressEvents => _progressController.stream;

  /// Waits for the CDN module script in `index.html` to expose
  /// `window.webllm`, then creates the engine. Throws [StateError] with a
  /// user-readable message when the library never arrives.
  Future<WebLlmEngine> _ensureEngine() async {
    final engine = _engine;
    if (engine != null) return engine;

    // The module import from jsdelivr is asynchronous; on a slow connection
    // the user can reach this point before it resolves.
    for (var attempt = 0; attempt < 40 && !webLlmJsAvailable(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!webLlmJsAvailable()) {
      throw StateError(
        'The on-device runtime (@mlc-ai/web-llm) did not load from the CDN. '
        'Check your connection and reload the page.',
      );
    }

    final created = WebLlmEngine(
      <String, Object?>{
            'appConfig': webLlmPrebuiltAppConfig,
            'useWebWorker': false,
            'logLevel': kDebugMode ? 'INFO' : 'WARN',
          }.jsify()!
          as JSObject,
    );
    created.setInitProgressCallback(
      ((JSObject report) {
        final r = report as WebLlmProgressReport;
        if (!_progressController.isClosed) {
          _progressController.add(
            WebLlmProgress(
              fraction: r.progress?.toDartDouble,
              text: r.text?.toDart ?? '',
            ),
          );
        }
      }).toJS,
    );
    return _engine = created;
  }

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {
    if (!webLlmWebGpuAvailable()) {
      throw StateError(
        'This browser has no WebGPU support, which on-device inference '
        'needs. Use Chrome/Edge or a recent Safari — or pick a hosted '
        'provider instead.',
      );
    }
    final engine = await _ensureEngine();
    if (loadedModelId == preset.id) return;
    final chatConfig = <String, Object?>{
      'context_window_size': preset.contextWindow,
      'temperature': preset.temperature,
      'top_p': preset.topP,
    }.jsify();
    try {
      await engine.reload(preset.id.toJS, chatConfig).toDart;
      loadedModelId = preset.id;
    } catch (e) {
      // An aborted/failed reload can leave the MLCEngine in a state where it
      // reports "ready" but cannot run inference — drop it so the next
      // attempt starts from a fresh engine.
      loadedModelId = null;
      _engine = null;
      throw StateError(
        'Failed to load ${preset.displayName}: ${_jsErrorText(e)}',
      );
    }
  }

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxTokens,
  }) async {
    final engine = _engine;
    if (engine == null || loadedModelId == null) {
      throw StateError('No on-device model loaded. Call loadModel() first.');
    }
    final request =
        <String, Object?>{
              'stream': true,
              'messages': [
                for (final m in messages)
                  {
                    'role': m.role,
                    'content': m.content,
                    'tool_call_id': ?m.toolCallId,
                  },
              ],
              if (tools != null && tools.isNotEmpty) ...{
                'tools': tools,
                // Ignored by web-llm (no validation), kept for OpenAI shape
                // fidelity; the Hermes function-calling template governs.
                'tool_choice': 'auto',
              },
              if (maxTokens != null) 'max_tokens': maxTokens,
              'stop': ['<|endoftext|>', '<|im_end|>', '</s>'],
            }.jsify()!
            as JSObject;

    final asyncIterable =
        await engine.chatCompletion(request).toDart as JSObject;

    final options =
        <String, Object?>{
              'maxTokens': maxTokens ?? 1 << 30,
              'onChunk': ((JSString content) {
                final text = content.toDart;
                if (text.isNotEmpty) onChunk(text);
              }).toJS,
              'onToolCalls': ((JSString toolCallsJson) {
                onToolCalls?.call(toolCallsJson.toDart);
              }).toJS,
              'onDone': ((JSString finishReason) {
                onDone?.call(finishReason.toDart);
              }).toJS,
              'onError': ((JSString error) {
                onError?.call(error.toDart);
              }).toJS,
            }.jsify()!
            as JSObject;

    final cancel = webLlmStreamWithCallbacks(asyncIterable, options);
    return () {
      cancel.callAsFunction(null);
    };
  }

  @override
  Future<void> interrupt() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.interruptGenerate().toDart;
    } catch (_) {
      // Interrupt during a reload (or with nothing generating) rejects on
      // the JS side; cancellation is best-effort.
    }
  }

  @override
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId) async {
    try {
      final info =
          await webLlmModelCacheInfo(modelId.toJS).toDart
              as WebLlmModelCacheInfoJs;
      return WebLlmCacheInfo(
        cached: info.cached?.toDart ?? false,
        bytes: info.bytes?.toDartInt,
      );
    } catch (_) {
      // CacheStorage unavailable (blocked, private mode) → unknown.
      return null;
    }
  }

  @override
  Future<void> deleteCachedModel(String modelId) async {
    await webLlmDeleteModel(modelId.toJS).toDart;
    if (loadedModelId == modelId) {
      // The loaded model's weights are gone — drop the engine so the next
      // loadModel re-downloads instead of failing obscurely mid-inference.
      loadedModelId = null;
      _engine = null;
    }
  }
}

String _jsErrorText(Object error) {
  final text = error.toString();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}
