// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Minimal `dart:js_interop` bindings for `@huggingface/transformers` loaded
/// from CDN.
///
/// `web/index.html` exposes the library as `window.transformersjs` via an
/// ES-module import
/// (`https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.2.0/+esm`) and
/// `web/transformers_js_helpers.js` installs the stateful helpers
/// (`window.transformersJsLoad`, `window.transformersJsChat`, cache
/// management) that own the processor/model/streamer objects — only plain
/// values (strings, maps, callbacks) cross this boundary, so no bindings for
/// the library's own classes are needed.
///
/// Web-only: imported solely by `transformers_js_service_web.dart`, which is
/// reachable only through the `dart.library.html` branch of
/// `transformers_js_service.dart`.
library;

import 'dart:js_interop';

/// The `window.transformersjs` module object; `null` until the CDN module
/// import in `index.html` completes (or forever, when the CDN is
/// unreachable).
@JS('transformersjs')
external JSObject? get _transformersJs;

/// `navigator.gpu`; `null` on browsers without WebGPU.
@JS('navigator.gpu')
external JSAny? get _navigatorGpu;

/// Whether the `@huggingface/transformers` module has loaded.
bool transformersJsLibraryAvailable() => _transformersJs != null;

/// Whether the browser exposes WebGPU (Chrome/Edge, newer Safari).
bool transformersJsWebGpuAvailable() => _navigatorGpu != null;

/// Helper from `web/transformers_js_helpers.js`: downloads and instantiates
/// the model ([modelId], [dtypeJson] a JSON-encoded per-component dtype map,
/// [allowlistJson] a JSON-encoded list of repo-relative file paths allowed
/// to download) with WebGPU. While loading, the helper wraps the library's
/// `env.fetch` and rejects any repo URL outside the allowlist, so no file
/// outside the requested dtype set can download. [onProgress] receives one
/// JSON-encoded raw event per update (`{status, file, loaded, total}`) —
/// aggregation happens Dart-side ([TransformersJsProgressAggregator]).
/// Resolves when the model is ready; rejects with a user-readable error.
@JS('transformersJsLoad')
external JSPromise transformersJsLoad(
  JSString modelId,
  JSString dtypeJson,
  JSString allowlistJson,
  JSFunction onProgress,
);

/// Helper from `web/transformers_js_helpers.js`: runs one streaming chat
/// turn against the loaded model. [options] carries `messages`
/// (`[{role, content, images}]`), `maxTokens`, and the `onChunk` / `onDone`
/// / `onError` callbacks; exactly one of `onDone(finishReason)` /
/// `onError(message)` fires. Returns a cancel function that interrupts the
/// generation.
@JS('transformersJsChat')
external JSFunction transformersJsChat(JSObject options);

/// Helper from `web/transformers_js_helpers.js`: interrupts any in-flight
/// generation (no-op when idle).
@JS('transformersJsInterrupt')
external void transformersJsInterrupt();

/// Helper from `web/transformers_js_helpers.js`: releases the loaded model
/// and processor (used when the cached weights were deleted).
@JS('transformersJsUnload')
external void transformersJsUnload();

/// Helper from `web/transformers_js_helpers.js`: scans CacheStorage for
/// entries whose URL contains the model id, reporting `{cached, bytes}`
/// (`bytes` sums the entries' `content-length` headers; `null` when
/// unknown).
@JS('transformersJsModelCacheInfo')
external JSPromise transformersJsModelCacheInfo(JSString modelId);

/// Helper from `web/transformers_js_helpers.js`: deletes every CacheStorage
/// entry whose URL contains the model id (ONNX weights, tokenizer, config).
@JS('transformersJsDeleteModel')
external JSPromise transformersJsDeleteModel(JSString modelId);

/// The `{cached, bytes}` object returned by [transformersJsModelCacheInfo].
extension type TransformersJsModelCacheInfoJs._(JSObject _)
    implements JSObject {
  /// Whether any cache entries match the model id.
  external JSBoolean? get cached;

  /// Sum of the matched entries' `content-length` headers, when known.
  external JSNumber? get bytes;
}
