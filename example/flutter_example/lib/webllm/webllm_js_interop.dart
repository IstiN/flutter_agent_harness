// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Minimal `dart:js_interop` bindings for `@mlc-ai/web-llm` loaded from CDN.
///
/// `web/index.html` exposes the library as `window.webllm` via an ES-module
/// import (`https://cdn.jsdelivr.net/npm/@mlc-ai/web-llm@0.2.84/+esm`) and
/// installs `window.webllmStreamWithCallbacks` from `web/webllm_helpers.js`.
/// Only the surface the example app needs is wrapped: engine construction,
/// model reload, streaming chat completion, init-progress callbacks, and
/// generation interrupt.
///
/// Web-only: imported solely by `webllm_service_web.dart`, which is reachable
/// only through the `dart.library.html` branch of `webllm_service.dart`.
library;

import 'dart:js_interop';

/// The `window.webllm` module object; `null` until the CDN module import in
/// `index.html` completes (or forever, when the CDN is unreachable).
@JS('webllm')
external JSObject? get _webllm;

/// `navigator.gpu`; `null` on browsers without WebGPU.
@JS('navigator.gpu')
external JSAny? get _navigatorGpu;

/// Whether the `@mlc-ai/web-llm` module has loaded.
bool webLlmJsAvailable() => _webllm != null;

/// Whether the browser exposes WebGPU (Chrome/Edge, newer Safari).
bool webLlmWebGpuAvailable() => _navigatorGpu != null;

/// The `webllm.MLCEngine` class (non-worker mode; the demo runs on the main
/// thread like the reference project — a worker build needs extra bundling).
@JS('webllm.MLCEngine')
extension type WebLlmEngine._(JSObject _) implements JSObject {
  /// Creates an engine from a config object (`{appConfig, logLevel,
  /// useWebWorker}`).
  external factory WebLlmEngine(JSObject config);

  /// Downloads (or loads from CacheStorage) and compiles [modelId].
  external JSPromise reload(JSString modelId, JSAny? chatConfig);

  /// Runs a chat completion; with `stream: true` the promise resolves to a
  /// JS async iterable of OpenAI-style chunks.
  external JSPromise chatCompletion(JSObject request);

  /// Registers the engine-init progress callback
  /// (`{progress, text, timeElapsed}` reports).
  external void setInitProgressCallback(JSFunction callback);

  /// Stops the in-flight generation.
  external JSPromise interruptGenerate();
}

/// `webllm.prebuiltAppConfig` — the registry of MLC prebuilt models.
@JS('webllm.prebuiltAppConfig')
external JSObject? get webLlmPrebuiltAppConfig;

/// Helper from `web/webllm_helpers.js`: consumes the chat-completion async
/// iterable and forwards text deltas through `options.onChunk` and
/// `delta.tool_calls` arrays (JSON-encoded) through `options.onToolCalls`,
/// terminating with `options.onDone(finishReason)` or `options.onError`.
/// Returns a cancel function that breaks the iterator loop early.
@JS('webllmStreamWithCallbacks')
external JSFunction webLlmStreamWithCallbacks(
  JSObject asyncIterable,
  JSObject options,
);

/// Helper from `web/webllm_helpers.js`: scans CacheStorage for entries whose
/// URL contains the model id, reporting `{cached, bytes}` (`bytes` sums the
/// entries' `content-length` headers; `null` when unknown).
@JS('webllmModelCacheInfo')
external JSPromise webLlmModelCacheInfo(JSString modelId);

/// Helper from `web/webllm_helpers.js`: deletes every CacheStorage entry
/// whose URL contains the model id (weights and model library).
@JS('webllmDeleteModel')
external JSPromise webLlmDeleteModel(JSString modelId);

/// The `{cached, bytes}` object returned by [webLlmModelCacheInfo].
extension type WebLlmModelCacheInfoJs._(JSObject _) implements JSObject {
  /// Whether any cache entries match the model id.
  external JSBoolean? get cached;

  /// Sum of the matched entries' `content-length` headers, when known.
  external JSNumber? get bytes;
}

/// One init-progress report passed to [WebLlmEngine.setInitProgressCallback].
extension type WebLlmProgressReport._(JSObject _) implements JSObject {
  /// Download/init fraction in `0..1`.
  external JSNumber? get progress;

  /// Human-readable status line.
  external JSString? get text;
}
