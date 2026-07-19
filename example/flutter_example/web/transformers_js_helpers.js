// transformers.js (@huggingface/transformers) helpers for the example app's
// on-device "Gemma (transformers.js)" provider.
// Loaded by web/index.html before flutter_bootstrap.js; the Dart side calls
// these via dart:js_interop (lib/transformers_js/transformers_js_js_interop.dart).
// The module itself arrives as window.transformersjs (ES-module import from
// jsdelivr in index.html); these helpers own the stateful objects
// (processor, model, stopping criteria) so only plain values cross the
// Dart boundary.
//
// The load/generate flow mirrors the proven webml-community/Gemma-4-WebGPU
// space: AutoProcessor + Gemma4ForConditionalGeneration.from_pretrained with
// a per-component dtype map and device 'webgpu', apply_chat_template +
// processor(text, images, audio, {add_special_tokens: false}),
// TextStreamer deltas, InterruptableStoppingCriteria for cancellation.

(function () {
  const state = {
    processor: null,
    model: null,
    modelId: null,
    criteria: null,
    loadPromise: null,
    loadingId: null,
  };

  // Leftover Gemma 4 control markers that can survive the streamer's
  // special-token skipping (belt and braces — the reference space filters
  // the same set).
  const CONTROL_RE = /<\|channel\|>|<channel\|>|<\|channel>|<turn\|>|<\|tool_response\|>|<\|tool_response>|<tool_response\|>/g;

  function library() {
    const tjs = window.transformersjs;
    if (!tjs) {
      throw new Error(
        'The on-device runtime (@huggingface/transformers) is not loaded yet.'
      );
    }
    return tjs;
  }

  function reset() {
    state.processor = null;
    state.model = null;
    state.modelId = null;
    state.criteria = null;
    state.loadPromise = null;
    state.loadingId = null;
  }

  // Downloads (or loads from CacheStorage) and instantiates the model.
  // dtypeJson is a JSON-encoded per-component dtype map
  // ({embed_tokens: 'q4f16', ...}); onProgress(fraction|null, text) reports
  // download progress (fraction in 0..1 when known). Resolves to the model id.
  window.transformersJsLoad = (modelId, dtypeJson, onProgress) => {
    if (state.model && state.modelId === modelId) {
      return Promise.resolve(modelId);
    }
    if (state.loadPromise && state.loadingId === modelId) {
      return state.loadPromise;
    }
    // Switching models: release the previous one so its GPU memory is freed.
    if (state.model) {
      try {
        if (typeof state.model.dispose === 'function') state.model.dispose();
      } catch (_) {
        /* disposal is best effort */
      }
      state.processor = null;
      state.model = null;
      state.modelId = null;
      state.criteria = null;
    }
    const tjs = library();
    const dtype = JSON.parse(dtypeJson);
    const report = (fraction, text) => {
      try {
        onProgress && onProgress(fraction, text);
      } catch (_) {
        /* progress reporting is best effort */
      }
    };
    state.loadingId = modelId;
    state.loadPromise = (async () => {
      try {
        report(null, 'Preparing model download…');
        const [processor, model] = await Promise.all([
          tjs.AutoProcessor.from_pretrained(modelId),
          tjs.Gemma4ForConditionalGeneration.from_pretrained(modelId, {
            dtype,
            device: 'webgpu',
            progress_callback: (e) => {
              if (!e || !e.status) return;
              if (e.status === 'progress_total') {
                // Library reports 0..100 across all files in flight.
                report(
                  typeof e.progress === 'number' ? e.progress / 100 : null,
                  'Downloading model weights…'
                );
              } else if (e.status === 'progress' && e.file) {
                report(null, 'Downloading ' + e.file);
              } else if (e.status === 'initiate' && e.file) {
                report(null, 'Starting download: ' + e.file);
              } else if (e.status === 'ready') {
                report(1, 'Model ready');
              }
            },
          }),
        ]);
        state.processor = processor;
        state.model = model;
        state.modelId = modelId;
        state.criteria = new tjs.InterruptableStoppingCriteria();
        report(1, 'Model ready');
        return modelId;
      } catch (e) {
        // Drop partial state so the next attempt starts fresh.
        reset();
        throw e;
      } finally {
        state.loadPromise = null;
        state.loadingId = null;
      }
    })();
    return state.loadPromise;
  };

  // Runs one streaming chat turn against the loaded model.
  // options: {
  //   messages: [{role, content, images: [dataUri, ...]}],
  //   maxTokens: number,
  //   onChunk(text), onDone(finishReason), onError(message)
  // }
  // Exactly one of onDone/onError fires. Returns a cancel function that
  // interrupts the generation (generate() then resolves normally and onDone
  // still fires — the Dart side maps the token-cancel to "aborted").
  window.transformersJsChat = (options) => {
    let cancelled = false;
    const cancel = () => {
      cancelled = true;
      if (state.criteria) state.criteria.interrupt();
    };
    const run = async () => {
      const onChunk = options && options.onChunk;
      const onDone = options && options.onDone;
      const onError = options && options.onError;
      try {
        const tjs = library();
        if (!state.model || !state.processor || !state.criteria) {
          throw new Error('No on-device model loaded. Call loadModel() first.');
        }
        const messages = (options && options.messages) || [];
        const maxTokens = (options && options.maxTokens) || 2048;

        // Shape messages for the chat template: image turns use typed
        // content parts; the pixel data goes to the processor separately.
        const templateMessages = [];
        const images = [];
        for (const m of messages) {
          const uris = m.images || [];
          if (uris.length > 0) {
            const parts = [];
            for (const uri of uris) {
              parts.push({ type: 'image' });
              images.push(await tjs.RawImage.read(uri));
            }
            if (m.content && m.content.trim().length > 0) {
              parts.push({ type: 'text', text: m.content });
            }
            templateMessages.push({ role: m.role, content: parts });
          } else {
            templateMessages.push({ role: m.role, content: m.content });
          }
        }

        const text = state.processor.apply_chat_template(templateMessages, {
          add_generation_prompt: true,
        });
        const inputs = await state.processor(
          text,
          images.length > 0 ? images : null,
          null,
          { add_special_tokens: false }
        );

        state.criteria.reset();
        const streamer = new tjs.TextStreamer(state.processor.tokenizer, {
          skip_prompt: true,
          skip_special_tokens: true,
          callback_function: (piece) => {
            if (cancelled || !onChunk) return;
            const chunk = String(piece).replace(CONTROL_RE, '');
            if (chunk) onChunk(chunk);
          },
        });

        const outputs = await state.model.generate(
          Object.assign({}, inputs, {
            max_new_tokens: maxTokens,
            do_sample: false,
            streamer,
            stopping_criteria: [state.criteria],
          })
        );

        // Finish reason: transformers.js reports none, so derive it — the
        // output sequence includes the prompt; hitting the cap means length.
        let reason = 'stop';
        try {
          const promptLen = inputs.input_ids.dims.at(-1);
          const totalLen = outputs.dims.at(-1);
          if (totalLen - promptLen >= maxTokens) reason = 'length';
        } catch (_) {
          /* dims introspection is best effort */
        }
        onDone && onDone(reason);
      } catch (e) {
        onError && onError(String((e && e.message) || e));
      }
    };
    run();
    return cancel;
  };

  // Interrupts any in-flight generation (no-op when idle).
  window.transformersJsInterrupt = () => {
    if (state.criteria) state.criteria.interrupt();
  };

  // Releases the loaded model and processor (used after the cached weights
  // were deleted, so the next load re-downloads).
  window.transformersJsUnload = () => {
    try {
      if (state.model && typeof state.model.dispose === 'function') {
        state.model.dispose();
      }
    } catch (_) {
      /* disposal is best effort */
    }
    reset();
  };

  // Reports whether a model's weights are in the browser CacheStorage
  // (transformers.js caches downloads under huggingface.co URLs containing
  // the repo id). Resolves to {cached: boolean, bytes: number|null} — bytes
  // sums the matched entries' content-length headers when available,
  // without reading the bodies.
  window.transformersJsModelCacheInfo = async (modelId) => {
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

  // Deletes a model's weights (and tokenizer/config files) from the browser
  // CacheStorage: every entry whose URL contains the model id.
  window.transformersJsDeleteModel = async (modelId) => {
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
})();
