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
