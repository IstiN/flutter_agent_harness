// WebLLM (@mlc-ai/web-llm) helpers for the example app.
// Loaded by web/index.html before flutter_bootstrap.js; the Dart side calls
// window.webllmStreamWithCallbacks via dart:js_interop
// (lib/webllm/webllm_js_interop.dart).
//
// Adapted from the flutter_agent_memory demo's index.html stream helper.

// Consumes the async iterable returned by
// MLCEngine.chatCompletion({stream: true}) and forwards each text delta via
// options.onChunk(content). Exactly one of options.onDone()/onError(message)
// fires at the end. Returns a cancel function that breaks the iterator loop.
window.webllmStreamWithCallbacks = (asyncIterable, options) => {
  const maxTokens = options?.maxTokens ?? Number.MAX_SAFE_INTEGER;
  let tokens = 0;
  let done = false;
  let iterator = null;

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
        const content = value?.choices?.[0]?.delta?.content ?? '';
        if (content) {
          tokens += 1;
          options?.onChunk?.(content);
        }
        if (tokens >= maxTokens) break;
      }
    } catch (e) {
      console.error('[webllm] stream error:', e);
      options?.onError?.(String(e));
    } finally {
      done = true;
      options?.onDone?.();
    }
  };

  run();
  return cancel;
};
