// WebLLM (@mlc-ai/web-llm) helpers for the example app.
// Loaded by web/index.html before flutter_bootstrap.js; the Dart side calls
// window.webllmStreamWithCallbacks via dart:js_interop
// (lib/webllm/webllm_js_interop.dart).
//
// Adapted from the flutter_agent_memory demo's index.html stream helper.

// Consumes the async iterable returned by
// MLCEngine.chatCompletion({stream: true}) and forwards:
//  - each text delta via options.onChunk(content),
//  - each delta.tool_calls array via options.onToolCalls(jsonString) in the
//    OpenAI streaming shape (WebLLM function calling delivers complete tool
//    calls in the final chunk, so this fires at most once per request),
//  - exactly one of options.onDone(finishReason)/onError(message) at the end.
// Returns a cancel function that breaks the iterator loop.
window.webllmStreamWithCallbacks = (asyncIterable, options) => {
  const maxTokens = options?.maxTokens ?? Number.MAX_SAFE_INTEGER;
  let tokens = 0;
  let done = false;
  let iterator = null;
  let finishReason = '';

  const cancel = () => {
    if (done) return;
    done = true;
    if (iterator && typeof iterator.return === 'function') {
      iterator.return().catch(() => {});
    }
  };

  const run = async () => {
    try {
      iterator = asyncIterable[Symbol.asyncIterator]();
      while (!done) {
        const { value, done: iterDone } = await iterator.next();
        if (iterDone || done) break;
        const choice = value?.choices?.[0];
        const content = choice?.delta?.content ?? '';
        if (content) {
          tokens += 1;
          options?.onChunk?.(content);
        }
        const toolCalls = choice?.delta?.tool_calls;
        if (toolCalls && toolCalls.length > 0) {
          options?.onToolCalls?.(JSON.stringify(toolCalls));
        }
        if (choice?.finish_reason) {
          finishReason = choice.finish_reason;
        }
        if (tokens >= maxTokens) break;
      }
    } catch (e) {
      console.error('[webllm] stream error:', e);
      options?.onError?.(String(e));
    } finally {
      done = true;
      options?.onDone?.(finishReason);
    }
  };

  run();
  return cancel;
};

// Reports whether a model's weights are in the browser CacheStorage (WebLLM
// caches downloads under URLs that contain the model id). Resolves to
// {cached: boolean, bytes: number|null} — bytes sums the matched entries'
// content-length headers when available, without reading the bodies.
// Adapted from the flutter_agent_memory demo's cache helpers.
window.webllmModelCacheInfo = async (modelId) => {
  try {
    const cacheNames = await caches.keys();
    for (const name of cacheNames) {
      const cache = await caches.open(name);
      const keys = await cache.keys();
      const matched = keys.filter((req) => req.url.includes(modelId));
      if (matched.length > 0) {
        let bytes = 0;
        let known = false;
        for (const req of matched) {
          const resp = await cache.match(req);
          const len = resp && resp.headers.get('content-length');
          if (len) {
            const n = parseInt(len, 10);
            if (!Number.isNaN(n)) {
              bytes += n;
              known = true;
            }
          }
        }
        return { cached: true, bytes: known ? bytes : null };
      }
    }
    return { cached: false, bytes: null };
  } catch {
    return { cached: false, bytes: null };
  }
};

// Deletes a model's weights (and model library) from the browser
// CacheStorage: every entry whose URL contains the model id.
window.webllmDeleteModel = async (modelId) => {
  const cacheNames = await caches.keys();
  for (const name of cacheNames) {
    const cache = await caches.open(name);
    const keys = await cache.keys();
    for (const req of keys) {
      if (req.url.includes(modelId)) {
        await cache.delete(req);
      }
    }
  }
};
