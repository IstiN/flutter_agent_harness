// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-IO stub for the Gemma engine: on-device inference needs the
/// `flutter_gemma` plugin (iOS/Android), so every operation reports
/// unavailability instead of failing obscurely.
library;

import 'gemma_types.dart';

/// Returns a stub [GemmaEngineApi] that reports unavailable.
GemmaEngineApi createGemmaService() => GemmaService();

/// A [GemmaEngineApi] that reports on-device inference as unavailable.
final class GemmaService implements GemmaEngineApi {
  @override
  bool get isAvailable => false;

  @override
  String? get loadedModelId => null;

  @override
  Stream<GemmaProgress> get progressEvents => const Stream.empty();

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => false;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) => Future.error(StateError(gemmaUnsupportedPlatformMessage));

  @override
  Future<void> loadModel(GemmaModelPreset preset) =>
      Future.error(StateError(gemmaUnsupportedPlatformMessage));

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
  }) => Future.error(StateError(gemmaUnsupportedPlatformMessage));

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unload() async {}
}
