// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web implementation of [TransformersJsEngineApi] over
/// `@huggingface/transformers` (ONNX Runtime Web, WebGPU).
///
/// Mirrors `webllm_service_web.dart`: one model singleton per page (shared
/// between the settings form's pre-load and the [AgentService] stream
/// function), weights download into the browser CacheStorage on first use,
/// streaming via the `transformersJsChat` JS helper, cancellation via
/// `InterruptableStoppingCriteria` (both `interrupt()` and the returned
/// cancel function call it).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'transformers_js_js_interop.dart';
import 'transformers_js_types.dart';

/// Returns the process-wide [TransformersJsEngineApi] singleton.
///
/// The engine (and its downloaded weights) is shared between the settings
/// form (which pre-loads the model with a progress bar) and the
/// [AgentService] stream function, so the model picked at connect time is
/// the one already warm.
TransformersJsEngineApi createTransformersJsService() =>
    _instance ??= TransformersJsService._();

TransformersJsService? _instance;

/// Owns the loaded model id; the JS-side processor/model/streamer objects
/// live in `web/transformers_js_helpers.js`.
final class TransformersJsService implements TransformersJsEngineApi {
  TransformersJsService._();

  @override
  String? loadedModelId;

  final _progressController =
      StreamController<TransformersJsProgress>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<TransformersJsProgress> get progressEvents =>
      _progressController.stream;

  /// Waits for the CDN module script in `index.html` to expose
  /// `window.transformersjs`. Throws [StateError] with a user-readable
  /// message when the library never arrives.
  Future<void> _ensureLibrary() async {
    // The module import from jsdelivr is asynchronous; on a slow connection
    // the user can reach this point before it resolves.
    for (
      var attempt = 0;
      attempt < 40 && !transformersJsLibraryAvailable();
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!transformersJsLibraryAvailable()) {
      throw StateError(
        'The on-device runtime (@huggingface/transformers) did not load '
        'from the CDN. Check your connection and reload the page.',
      );
    }
  }

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) async {
    if (!transformersJsWebGpuAvailable()) {
      throw StateError(
        'This browser has no WebGPU support, which on-device inference '
        'needs. Use Chrome/Edge or a recent Safari — or pick a hosted '
        'provider instead.',
      );
    }
    await _ensureLibrary();
    if (loadedModelId == preset.id) return;
    try {
      await transformersJsLoad(
        preset.id.toJS,
        jsonEncode(preset.dtype).toJS,
        ((JSNumber? fraction, JSString text) {
          if (!_progressController.isClosed) {
            _progressController.add(
              TransformersJsProgress(
                fraction: fraction?.toDartDouble,
                text: text.toDart,
              ),
            );
          }
        }).toJS,
      ).toDart;
      loadedModelId = preset.id;
    } catch (e) {
      // A failed load can leave JS-side partial state; the helper drops it,
      // so the next attempt starts fresh.
      loadedModelId = null;
      throw StateError(
        'Failed to load ${preset.displayName}: ${_jsErrorText(e)}',
      );
    }
  }

  @override
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async {
    if (loadedModelId == null) {
      throw StateError('No on-device model loaded. Call loadModel() first.');
    }
    final options =
        <String, Object?>{
              'messages': [
                for (final m in messages)
                  {'role': m.role, 'content': m.content, 'images': m.images},
              ],
              'maxTokens': maxTokens ?? 2048,
              'onChunk': ((JSString content) {
                final text = content.toDart;
                if (text.isNotEmpty) onChunk(text);
              }).toJS,
              'onDone': ((JSString finishReason) {
                onDone?.call(finishReason.toDart);
              }).toJS,
              'onError': ((JSString error) {
                onError?.call(error.toDart);
              }).toJS,
            }.jsify()!
            as JSObject;

    final cancel = transformersJsChat(options);
    return () {
      cancel.callAsFunction(null);
    };
  }

  @override
  Future<void> interrupt() async {
    try {
      transformersJsInterrupt();
    } catch (_) {
      // Interrupt with nothing generating is a no-op JS-side; cancellation
      // is best-effort.
    }
  }

  @override
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async {
    try {
      final info =
          await transformersJsModelCacheInfo(modelId.toJS).toDart
              as TransformersJsModelCacheInfoJs;
      return TransformersJsCacheInfo(
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
    await transformersJsDeleteModel(modelId.toJS).toDart;
    if (loadedModelId == modelId) {
      // The loaded model's weights are gone — drop the JS-side model so the
      // next loadModel re-downloads instead of failing obscurely
      // mid-inference.
      loadedModelId = null;
      transformersJsUnload();
    }
  }
}

String _jsErrorText(Object error) {
  final text = error.toString();
  return text.length > 300 ? '${text.substring(0, 300)}…' : text;
}
