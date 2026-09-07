/// Engine bootstrap JS sources (section 7 of the js-extension design).
///
/// These are const Strings embedded in the Dart binary (NOT prompt files).
/// They are also the parity-fixture surface: keep them engine-agnostic — the
/// core never detects the engine; transports supply platform details.
///
/// An adapter composes its bootstrap as
/// `transportJs + '\n;\n' + kExtBootstrapCoreJs`, appends the extension's
/// `main.js` with its own evaluation, then obtains the registration payload
/// via `__extCommit()`.
library;

/// Shared, engine-agnostic core: the `jsr.ext.*` API, the handle table, the
/// pending-promise map, and the commit/invoke/ping entry points the host
/// adapter drives.
///
/// Transport contract (a `kExtTransport*Js` source MUST be evaluated first):
///  - `__extEngineId` — engine identity string returned by `__extPing()`.
///  - `__extTransport.call(method, args)` — sends
///    `{seq, method, args}` to the host and returns a Promise resolved by
///    `__extDeliver({seq, ok, value})` / `__extDeliver({seq, ok:false, error})`.
const String kExtBootstrapCoreJs = '''
// jsr.ext core bootstrap — engine-agnostic; a transport source must already
// have defined __extEngineId and __extTransport.call(method, args).
(function (g) {
  'use strict';
  if (!g.__extHandles) { g.__extHandles = new Map(); }
  var handles = g.__extHandles;
  var nextHandle = 0;
  var seq = 0;
  var pending = new Map();
  var registrations = { tools: [], hooks: [], slash: [], flows: [] };

  // Transport support: the transport allocates a seq, awaits on it, and sends
  // the request; host responses arrive through __extDeliver.
  g.__extNextSeq = function () {
    seq += 1;
    return seq;
  };
  g.__extExpect = function (s) {
    return new Promise(function (resolve, reject) {
      pending.set(s, { resolve: resolve, reject: reject });
    });
  };
  // Resolves the bridge call keyed by msg.seq: {seq, ok:true, value} or
  // {seq, ok:false, error}. Unknown/late seqs are ignored. Returns whether a
  // pending call was settled.
  g.__extDeliver = function (msg) {
    if (!msg || typeof msg.seq === 'undefined') { return false; }
    var p = pending.get(msg.seq);
    if (!p) { return false; }
    pending.delete(msg.seq);
    if (msg.ok) { p.resolve(msg.value); }
    else { p.reject(new Error(msg.error || 'ext: bridge call failed')); }
    return true;
  };
  // True while the bridge call with this seq still awaits its response (used
  // by the stdio transport's nested pump).
  g.__extIsPending = function (s) {
    return pending.has(s);
  };

  function call(method, args) {
    return g.__extTransport.call(method, args === undefined ? {} : args);
  }
  function bind(fn) {
    nextHandle += 1;
    handles.set(nextHandle, fn);
    return nextHandle;
  }
  function needDef(d, what) {
    if (!d || typeof d !== 'object') { throw new Error('ext: ' + what + ' requires a definition object'); }
    return d;
  }
  function needName(name, what) {
    if (typeof name !== 'string' || name.length === 0) { throw new Error('ext: ' + what + ' requires a name'); }
    return name;
  }
  function optString(d, key) {
    return typeof d[key] === 'string' ? d[key] : '';
  }

  var ext = {
    // jsr.ext.registerTool({name, description, schema?, tier?, call}) → handle
    // call(args) returns String | {text} | {error} (or a Promise of those).
    registerTool: function (def) {
      needDef(def, 'registerTool');
      var h = bind(def.call);
      registrations.tools.push({
        name: needName(def.name, 'registerTool'),
        description: optString(def, 'description'),
        parameters: def.schema && typeof def.schema === 'object' ? def.schema : {},
        tier: typeof def.tier === 'string' ? def.tier : 'exec',
        handle: h
      });
      return h;
    },
    // jsr.ext.onHook(event, fn) → handle; event is a wire hook-event name
    // ('onSessionStart', 'beforeToolCall', ...); fn(payload) result is
    // validated Dart-side.
    onHook: function (event, fn) {
      needName(event, 'onHook');
      var h = bind(fn);
      registrations.hooks.push({ event: event, handle: h });
      return h;
    },
    // jsr.ext.registerSlashCommand(name, {description?, run(args, io)}) →
    // handle; host invokes the bound wrapper with {args:[...]} (documented)
    // or the raw args array — both accepted.
    registerSlashCommand: function (name, opts) {
      needDef(opts, 'registerSlashCommand');
      var bare = needName(name, 'registerSlashCommand');
      if (bare.charAt(0) === '/') { bare = bare.slice(1); }
      var io = {
        write: function (text) { return ext.io.write(text); },
        writeln: function (text) { return ext.io.writeln(text); }
      };
      var h = bind(function (payload) {
        var args = payload && payload.args ? payload.args : (Array.isArray(payload) ? payload : []);
        return opts.run(args, io);
      });
      registrations.slash.push({ name: bare, description: optString(opts, 'description'), handle: h });
      return h;
    },
    menus: {
      // jsr.ext.menus.registerProviderFlow({id, title?, description?, fields,
      // onSubmit}) → handle; onSubmit(values) →
      // {providerName?, baseUrl, apiKey?, modelName?} | null.
      registerProviderFlow: function (def) {
        needDef(def, 'registerProviderFlow');
        var id = needName(def.id, 'registerProviderFlow');
        var fields = [];
        if (def.fields && typeof def.fields.length === 'number') {
          for (var i = 0; i < def.fields.length; i += 1) {
            var f = def.fields[i] || {};
            fields.push({ name: f.name, label: f.label, secret: f.secret === true });
          }
        }
        var h = bind(def.onSubmit);
        registrations.flows.push({
          id: id,
          title: optString(def, 'title'),
          description: optString(def, 'description'),
          fields: fields,
          handle: h
        });
        return h;
      }
    },
    session: {
      appendNote: function (text) { return call('session.appendNote', { text: String(text === undefined ? '' : text) }); },
      enqueueFollowUp: function (text) { return call('session.enqueueFollowUp', { text: String(text === undefined ? '' : text) }); }
    },
    fs: {
      // Resolves with the file content (read-only, confined to the project
      // root); rejects with an error string on escape/denial.
      readFile: function (path) { return call('fs.readFile', { path: path }); }
    },
    exec: {
      // jsr.ext.exec.run({command, args?, timeoutMs?}) →
      // {exitCode, stdout, stderr, timedOut}.
      run: function (opts) {
        needDef(opts, 'exec.run');
        return call('exec.run', { command: opts.command, args: opts.args || [], timeoutMs: opts.timeoutMs });
      }
    },
    keys: {
      // Resolves with {granted: bool, name: string} — never a key value.
      request: function (name) { return call('keys.request', { name: name }); }
    },
    io: {
      write: function (text) { return call('io.write', { text: String(text === undefined ? '' : text) }); },
      writeln: function (text) { return call('io.writeln', { text: String(text === undefined ? '' : text) }); }
    },
    // Resolves with true/false for a capability name ('exec', 'fs', 'keys',
    // 'network', 'tools', 'menus').
    has: function (capability) { return call('has', { capability: capability }); }
  };
  g.jsr = { ext: ext };

  // Registration payload for the host adapter; pure read of the buffer.
  g.__extCommit = function () {
    return {
      tools: registrations.tools.map(function (t) {
        return { name: t.name, description: t.description, parameters: t.parameters, tier: t.tier, handle: t.handle };
      }),
      hooks: registrations.hooks.map(function (h) {
        return { event: h.event, handle: h.handle };
      }),
      slash: registrations.slash.map(function (s) {
        return { name: s.name, description: s.description, handle: s.handle };
      }),
      flows: registrations.flows.map(function (f) {
        return { id: f.id, title: f.title, description: f.description, fields: f.fields, handle: f.handle };
      })
    };
  };
  // Invokes the callback bound to handle with args (args shape depends on the
  // registration kind). Sync results and Promise results are both fine — the
  // adapter awaits settlement.
  g.__extInvoke = function (handle, args) {
    var fn = handles.get(handle);
    if (typeof fn !== 'function') { throw new Error('ext: no callback for handle ' + handle); }
    return fn(args);
  };
  g.__extPing = function () {
    return g.__extEngineId;
  };
  // Exposed for tests/inspection; the buffer behind __extCommit().
  g.__extRegistrations = registrations;
})(globalThis);
''';

/// stdio transport for the `qjs` CLI (quickjs / quickjs-ng): line-delimited
/// JSON on stdin/stdout.
///
/// Framing: one JSON object per `\n` line.
///  - JS → host request: `{"seq":1,"method":"fs.readFile","args":{"path":"x"}}`
///  - host → JS response: `{"seq":1,"ok":true,"value":...}` or
///    `{"seq":1,"ok":false,"error":"..."}`
///  - host → JS invoke: `{"invoke":1,"fn":"__extInvoke","args":[7,{"a":1}]}`
///  - JS → host invoke result: `{"invoke":1,"ok":true,"value":...}` or
///    `{"invoke":1,"ok":false,"error":"..."}`
const String kExtTransportStdioJs = '''
// stdio transport (qjs CLI): JSON lines on stdin/stdout; keeps the process
// alive reading stdin until EOF.
(function (g) {
  'use strict';
  g.__extEngineId = 'qjs-process';
  if (typeof std === 'undefined') { throw new Error('ext: stdio transport requires the qjs std module'); }

  function send(obj) {
    std.out.puts(JSON.stringify(obj) + '\\n');
    std.out.flush();
  }

  // Nested blocking pump for bridge round-trips: qjs has no async stdin
  // events, so a call must read its own response instead of relying on the
  // outer loop. Handles interleaved host invokes while waiting. Returns
  // false on EOF (call stays pending; the adapter's timeout applies).
  function pumpUntil(done) {
    for (;;) {
      if (done()) { return true; }
      var line = readLine();
      if (line === null) { return false; }
      handleLine(line);
    }
  }

  g.__extTransport = {
    call: function (method, args) {
      var s = g.__extNextSeq();
      var p = g.__extExpect(s);
      send({ seq: s, method: method, args: args === undefined ? {} : args });
      pumpUntil(function () { return !g.__extIsPending(s); });
      return p;
    }
  };

  function errorText(e) {
    return String(e && e.message ? e.message : e);
  }
  function handleLine(line) {
    var msg;
    try { msg = JSON.parse(line); } catch (e) { return; }
    if (!msg || typeof msg !== 'object') { return; }
    if (typeof msg.invoke !== 'undefined') {
      var id = msg.invoke;
      var fn = typeof msg.fn === 'string' ? g[msg.fn] : null;
      if (typeof fn !== 'function') {
        send({ invoke: id, ok: false, error: 'ext: no such function: ' + msg.fn });
        return;
      }
      var result;
      try { result = fn.apply(null, msg.args || []); }
      catch (e) {
        send({ invoke: id, ok: false, error: errorText(e) });
        return;
      }
      if (result && typeof result.then === 'function') {
        result.then(function (v) {
          send({ invoke: id, ok: true, value: v === undefined ? null : v });
        }, function (e) {
          send({ invoke: id, ok: false, error: errorText(e) });
        });
      } else {
        send({ invoke: id, ok: true, value: result === undefined ? null : result });
      }
    } else if (typeof msg.seq !== 'undefined') {
      g.__extDeliver(msg);
    }
  }

  function readLine() {
    return std.in.getline();
  }
  if (typeof os !== 'undefined' && typeof os.setTimeout === 'function') {
    // Event-loop branch (quickjs-ng): idle ticks serve host-initiated
    // invokes (bridge calls pump nested inside __extTransport.call); promise
    // jobs drain between ticks, so async invoke results are delivered.
    // EOF (null) stops the timer chain and lets the script end.
    var tick = function () {
      var line = readLine();
      if (line === null) { return; }
      handleLine(line);
      os.setTimeout(tick, 1);
    };
    os.setTimeout(tick, 1);
  } else {
    // Blocking fallback (engines without timers): sync invoke results only —
    // promise continuations never drain inside this loop.
    for (;;) {
      var line = readLine();
      if (line === null) { break; }
      handleLine(line);
    }
  }
})(globalThis);
''';

/// flutter_js transport: host calls bridge requests back through
/// `sendMessage('__ext_host', ...)`. The host delivers responses by
/// evaluating `__extDeliver(<json>)` in the runtime and drives invocations by
/// evaluating `__extInvoke(handle, args)`. No stdin loop — the host owns the
/// loop.
const String kExtTransportSendMessageJs = '''
// send-message transport (flutter_js): __ext_host channel.
(function (g) {
  'use strict';
  g.__extEngineId = 'flutter-js';
  if (typeof sendMessage !== 'function') {
    throw new Error('ext: send-message transport requires the flutter_js sendMessage global');
  }
  g.__extTransport = {
    call: function (method, args) {
      var s = g.__extNextSeq();
      var p = g.__extExpect(s);
      sendMessage('__ext_host', JSON.stringify({ seq: s, method: method, args: args === undefined ? {} : args }));
      return p;
    }
  };
})(globalThis);
''';

/// Web-worker transport: requests go out as
/// `postMessage({'__ext__': msg})`; incoming worker messages are unwrapped
/// from the same envelope and routed — `{seq,...}` settles bridge calls,
/// `{invoke,fn,args}` runs the named global and posts the result back.
const String kExtTransportPostMessageJs = '''
// post-message transport (web worker): envelope {'__ext__': msg}.
(function (g) {
  'use strict';
  g.__extEngineId = 'web-worker';
  if (typeof postMessage !== 'function') {
    throw new Error('ext: post-message transport requires a worker postMessage global');
  }
  g.__extTransport = {
    call: function (method, args) {
      var s = g.__extNextSeq();
      var p = g.__extExpect(s);
      postMessage({ __ext__: { seq: s, method: method, args: args === undefined ? {} : args } });
      return p;
    }
  };

  function errorText(e) {
    return String(e && e.message ? e.message : e);
  }
  function post(msg) {
    postMessage({ __ext__: msg });
  }
  g.onmessage = function (ev) {
    var data = ev && ev.data ? ev.data : null;
    if (!data || typeof data !== 'object') { return; }
    var msg = data.__ext__ !== undefined ? data.__ext__ : data;
    if (!msg || typeof msg !== 'object') { return; }
    if (typeof msg.invoke !== 'undefined') {
      var id = msg.invoke;
      var fn = typeof msg.fn === 'string' ? g[msg.fn] : null;
      if (typeof fn !== 'function') {
        post({ invoke: id, ok: false, error: 'ext: no such function: ' + msg.fn });
        return;
      }
      var result;
      try { result = fn.apply(null, msg.args || []); }
      catch (e) {
        post({ invoke: id, ok: false, error: errorText(e) });
        return;
      }
      Promise.resolve(result).then(function (v) {
        post({ invoke: id, ok: true, value: v === undefined ? null : v });
      }, function (e) {
        post({ invoke: id, ok: false, error: errorText(e) });
      });
    } else if (typeof msg.seq !== 'undefined') {
      g.__extDeliver(msg);
    }
  };
})(globalThis);
''';
