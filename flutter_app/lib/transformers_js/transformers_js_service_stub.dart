// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host (non-web) stub for the transformers.js engine: on-device inference
/// needs the browser-only `@huggingface/transformers` + ONNX Runtime Web
/// stack, so every operation reports unavailability instead of failing
/// obscurely.
library;

import 'transformers_js_types.dart';

/// Returns a stub [TransformersJsEngineApi] that reports unavailable.
TransformersJsEngineApi createTransformersJsService() =>
    TransformersJsService();

/// A [TransformersJsEngineApi] that reports on-device inference as
/// unavailable.
final class TransformersJsService implements TransformersJsEngineApi {
  @override
  bool get isAvailable => false;

  @override
  String? get loadedModelId => null;

  @override
  Stream<TransformersJsProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) =>
      Future.error(StateError(transformersJsUnavailableMessage));

  @override
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) => Future.error(StateError(transformersJsUnavailableMessage));

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async => null;

  @override
  Future<void> deleteCachedModel(String modelId) =>
      Future.error(StateError(transformersJsUnavailableMessage));
}
