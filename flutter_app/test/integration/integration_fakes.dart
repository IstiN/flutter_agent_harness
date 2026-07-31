// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared fakes/helpers for the integration-level flow tests: on-device
/// engine fakes (they keep the real plugin singletons off the host tests),
/// canned [StreamFunction]s, and the fake live-tile engine.
library;

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Fake [WebLlmEngineApi] answering cache queries from a script (mirrors
/// test/setup_prefill_test.dart — the form's engine scan must never reach
/// the real plugin singleton in host tests).
final class FakeWebLlmEngine implements WebLlmEngineApi {
  FakeWebLlmEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => null;

  @override
  Stream<WebLlmProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {}

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async => () {};

  @override
  Future<void> interrupt() async {}

  @override
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId) async =>
      cache[modelId];

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Fake [GemmaEngineApi] answering the installed-models scan from a script.
final class FakeGemmaEngine implements GemmaEngineApi {
  FakeGemmaEngine(this.installed);

  final List<GemmaInstalledModel> installed;

  @override
  bool get isAvailable => true;

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
  }) async {}

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {}

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
  }) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unload() async {}

  @override
  Future<List<GemmaInstalledModel>> installedModels() async => installed;

  @override
  Future<void> uninstall(String filename) async {}
}

/// Fake [TransformersJsEngineApi] answering cache queries from a script.
final class FakeTransformersJsEngine implements TransformersJsEngineApi {
  FakeTransformersJsEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;

  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => null;

  @override
  Stream<TransformersJsProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) async {}

  @override
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async => () {};

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async =>
      cache[modelId];

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// A [StreamFunction] that plays [turns] in order — one entry per model
/// call (tool-call turns re-enter the model, so a tool flow needs a
/// tool-call turn followed by a text turn).
StreamFunction scriptedTurns(List<AssistantMessage Function(Model)> turns) {
  var call = 0;
  return (model, context, {cancelToken}) {
    final message = turns[call < turns.length ? call++ : turns.length - 1](
      model,
    );
    final stream = AssistantMessageEventStream();
    stream.push(DoneEvent(reason: message.stopReason, message: message));
    stream.end();
    return stream;
  };
}

AssistantMessage textTurn(Model model, String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime(2026),
);

/// A tool-call turn: the loop executes every [ToolCall] in the content and
/// re-enters the model for the next turn.
AssistantMessage toolCallTurn(Model model, List<ToolCall> calls) =>
    AssistantMessage(
      content: calls,
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.toolUse,
      timestamp: DateTime(2026),
    );

ToolCall writeCall(String id, String path, String content) => ToolCall(
  id: id,
  name: 'write',
  arguments: {'path': path, 'content': content},
);

/// Fake tile engine for the live-tile launcher flows: emits a fixed tree,
/// no JavaScriptCore boot (the app_launcher_screen_test.dart pattern).
final class FakeTileEngine extends JsAppEngine {
  FakeTileEngine({
    required super.app,
    required super.env,
    required super.permissions,
    super.initialTheme,
  });

  @override
  Future<void> start() async {
    tree.value = const {
      'type': 'container',
      'alignment': 'center',
      'child': {'type': 'text', 'data': 'LIVE TILE'},
    };
  }

  @override
  Future<void> updateTheme(Map<String, dynamic> theme) async {}
}

TileEngineFactory fakeTileEngineFactory() =>
    ({
      required JsAppInfo app,
      required ExecutionEnv env,
      required AppPermissions permissions,
      required Map<String, dynamic> initialTheme,
    }) => FakeTileEngine(
      app: app,
      env: env,
      permissions: permissions,
      initialTheme: initialTheme,
    );
