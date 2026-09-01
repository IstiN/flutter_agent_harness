// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/contact_service.dart';
import 'package:fa/services/health_service.dart';
import 'package:fa/services/home_service.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/notify_service.dart';
import 'package:fa/services/video_service.dart';
import 'package:fa/services/video_tool.dart';

/// One chat message for the `jsr.fa.llm.chat/stream` bridge calls; [role] is
/// `user`, `assistant`, or `system`.
typedef FaLlmMessage = ({String role, String content});

/// LLM completion used by the `jsr.fa.llm*` bridge calls. Receives the
/// conversation and resolves with the assistant's reply text. When [onDelta]
/// is given (the `llm.stream` call), it reports text deltas as they arrive.
typedef FaLlmHandler =
    Future<Object?> Function(
      List<FaLlmMessage> messages, {
      void Function(String delta)? onDelta,
    });

/// Handler for platform bridges still without a real backend (health
/// actions other than `health.summary`). Receives the action name
/// (`health.stepsToday`, …) and args.
typedef FaPlatformHandler =
    Future<Object?> Function(String action, Map<String, Object?> args);

/// Read source for the host's merged secrets (dotenv + saved keys) behind
/// the `jsr.fa.keys.list/get` bridge calls; returns a fresh name → value
/// map on every call.
typedef FaHostKeysSource = Map<String, String> Function();

/// Host-side engine for one JS app: owns the [JsWidgetEngine], wires every
/// `jsr.*` I/O call through the shared [ExecutionEnv] and the app's
/// [AppPermissions], and persists JS storage across reloads.
///
/// Permission gates:
/// - `jsr.fetchJson` → [AppPermissions.network]
/// - `jsr.exec(<shell>)` → command must be in [AppPermissions.allowedCommands]
/// - `jsr.fa.llm` / `jsr.fa.llm.chat` / `jsr.fa.llm.stream` →
///   [AppPermissions.llm]
/// - `jsr.fa.calendar` → [AppPermissions.calendar] (real backend via
///   [CalendarApi]; requests OS access on first use)
/// - `jsr.fa.contacts.*` → [AppPermissions.contacts] (real backend via
///   [ContactApi]; requests OS access on first use)
/// - `jsr.fa.health.summary` → [AppPermissions.health] (real backend via
///   [HealthApi], iOS/macOS HealthKit; requests OS access on first use)
/// - `jsr.fa.home.*` (and the legacy `jsr.fa.homekit(action, …)` calls) →
///   [AppPermissions.homekit] (real backend via [HomeApi], iOS HomeKit;
///   requests OS access on first use)
/// - `jsr.fa.asr.record` / `jsr.fa.asr.transcribe` →
///   [AppPermissions.microphone] (real backend via [AsrApi]; requests OS
///   microphone access on first use; transcription rides the configured
///   OpenAI-compatible endpoint via [AsrTranscriber])
/// - `jsr.fa.notify.schedule` / `jsr.fa.notify.cancel` →
///   [AppPermissions.notifications] (real backend via [NotifyApi]; requests
///   OS notification access on first use)
/// - `jsr.fa.notify.schedule` / `jsr.fa.notify.cancel` →
///   [AppPermissions.notifications] (real backend via [NotifyApi]; requests
///   OS notification access on first use)
/// - `jsr.fa.media.generateImage` / `jsr.fa.media.speak` /
///   `jsr.fa.media.generateMusic` / `jsr.fa.media.generateVideo` /
///   `jsr.fa.media.readVideo` →
///   [AppPermissions.media] (endpoint resolution via [MediaGateway] over
///   `media_models.json` + the main connection, the same resolvers the
///   agent's media tools use; video reading via [VideoReader])
/// - `jsr.fa.keys.list` / `jsr.fa.keys.get` / `jsr.fa.keys.request` →
///   [AppPermissions.keys] (reads the host's merged secrets via
///   [FaHostKeysSource]; `request` opens the same native secret prompt the
///   agent's `request_secret` tool uses, via the injected
///   [RequestSecretCallback])
/// - other health actions → the matching flag (stubbed until the platform
///   implementations land — a granted call answers "not available").
class JsAppEngine {
  JsAppEngine({
    required this.app,
    required this.env,
    required this.permissions,
    this.entryFile = defaultEntryFile,
    this.llmHandler,
    this.platformHandler,
    this.calendar,
    this.contacts,
    this.health,
    this.home,
    this.asr,
    this.asrTranscriber,
    this.notify,
    this.mediaGateway,
    this.videoReader,
    this.keysSource,
    this.keyRequestHandler,
    this.hostLocale = 'en',
    this.initialTheme = const {},
    this._onLog,
  });

  /// The JS entry file [start] runs when no override is given.
  static const String defaultEntryFile = 'widget.js';

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissions permissions;

  /// The JS entry file inside the app folder (`apps/<id>/`) that [start]
  /// runs — [defaultEntryFile] for the full app, the tile entry
  /// ([JsTileWidgetInfo.entry]) when the engine powers a launcher live tile.
  final String entryFile;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;

  /// The `jsr.theme` map the app boots with (see `js_theme.dart`); later
  /// host theme changes are pushed via [updateTheme].
  final Map<String, dynamic> initialTheme;

  /// Calendar backend for `jsr.fa.calendar`; `null` uses the platform
  /// service ([createCalendarService] — a never-available stub on web).
  final CalendarApi? calendar;

  /// Contacts backend for `jsr.fa.contacts.*`; `null` uses the platform
  /// service ([createContactService] — a never-available stub on web).
  final ContactApi? contacts;

  /// Health backend for `jsr.fa.health.summary`; `null` uses the platform
  /// service ([createHealthService] — a never-available stub on web).
  final HealthApi? health;

  /// Home backend for `jsr.fa.home.*`; `null` uses the platform service
  /// ([createHomeService] — a never-available stub on web).
  final HomeApi? home;

  /// Microphone backend for `jsr.fa.asr.*`; `null` uses the platform
  /// service ([createAsrService] — a never-available stub on web).
  final AsrApi? asr;

  /// Transcriber for `jsr.fa.asr.transcribe`; `null` (no ASR-capable
  /// endpoint configured) answers with an actionable error.
  final AsrTranscriber? asrTranscriber;

  /// Notifications backend for `jsr.fa.notify.*`; `null` uses the platform
  /// service ([createNotifyService] — a never-available stub on web).
  final NotifyApi? notify;

  /// Media generation backend for `jsr.fa.media.*` (see [MediaGateway]);
  /// `null` answers with an actionable "not available in this session"
  /// error.
  final MediaGateway? mediaGateway;

  /// Video-reading backend for `jsr.fa.media.readVideo` (see [VideoReader]);
  /// `null` answers with an actionable "not available in this session"
  /// error.
  final VideoReader? videoReader;

  /// Host-secrets source behind `jsr.fa.keys.list/get` (see
  /// [FaHostKeysSource]); `null` answers with an actionable "not available
  /// in this session" error.
  final FaHostKeysSource? keysSource;

  /// The host UI locale exposed to the app as `jsr.locale` (ISO code, e.g.
  /// `'en'` / `'ru'`) — apps branch their strings on it (see the skill's
  /// localization section).
  final String hostLocale;

  /// Secret-request backend behind `jsr.fa.keys.request` — the host renders
  /// the same native prompt as the agent's `request_secret` tool and
  /// persists a grant; `null` answers with an actionable error, a `null`
  /// result (user declined) rejects the bridge call.
  final RequestSecretCallback? keyRequestHandler;
  final void Function(String line)? _onLog;

  /// The latest rendered UI tree; the view listens and rebuilds.
  final ValueNotifier<Map<String, dynamic>?> tree =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// Whether the running app registered a `jsr.onBack` handler — pushed by
  /// the bootstrap (`back.handler` bridge) every time the app assigns it.
  /// The view uses it for PopScope.canPop: with a handler, back gestures
  /// forward to JS first; without one the route pops natively.
  final ValueNotifier<bool> backHandlerRegistered = ValueNotifier(false);

  /// Called when the app declines to consume a back event (`back.close`
  /// bridge) — the host should pop the app route. Set by the view.
  void Function()? onCloseRequested;

  JsWidgetEngine? _engine;
  JsResolveCallback? _resolve;

  /// Process-wide lifecycle lock serializing [start] and [dispose] across
  /// ALL engines. Root cause of the TestFlight SIGSEGV: native JS contexts
  /// are address-keyed (`JavascriptCoreRuntime._instanceMap`) — an engine
  /// disposed LATE (its async dispose gap, or a deferred chain) can release
  /// the native context AFTER the allocator handed the same address to a
  /// NEW engine, freeing that engine's live context out from under it
  /// (use-after-free in `JSC::JSLock::lock`). Serializing start/dispose
  /// guarantees a native release always completes before the next native
  /// context is created.
  static Future<void> _lifecycleChain = Future<void>.value();

  /// Runs [action] after every previously queued lifecycle action.
  static Future<T> _lifecycle<T>(Future<T> Function() action) {
    final next = _lifecycleChain.then((_) => action());
    _lifecycleChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// True under `flutter test` (the binding class name, no dart:io so it's
  /// web-safe). There the static chain DEADLOCKS: a real engine start's
  /// native work never completes inside the widget-test fake zone, which
  /// would stall every later engine in the process. Tests exercise the
  /// unserialized path (the production hazard is native and untestable).
  static bool get _inWidgetTest {
    final binding = WidgetsBinding.instance;
    return binding.runtimeType.toString().contains('TestWidgetsFlutterBinding');
  }

  /// Serializes [action] process-wide in production; runs it directly
  /// under widget tests (see [_inWidgetTest]).
  static Future<T> _guardLifecycle<T>(Future<T> Function() action) =>
      _inWidgetTest ? action() : _lifecycle(action);

  Map<String, dynamic>? get exportedState => _engine?.exportedState;
  List<Map<String, dynamic>> peekLogs() => _engine?.peekLogs() ?? const [];

  /// Starts (or restarts) the JS engine with the current [entryFile].
  Future<void> start() => _guardLifecycle(_start);

  Future<void> _start() async {
    final old = _engine;
    _engine = null;
    if (old != null) await old.dispose();
    backHandlerRegistered.value = false;

    if (!app.supportsPlatform(currentFaPlatform)) {
      throw StateError("App '${app.id}' is not enabled on $currentFaPlatform");
    }

    // Log WHICH app boots — engine-start lines in the debug log used to
    // be indistinguishable between apps (and tiles vs full apps).
    AppLog.i('apps', 'engine start: ${app.id}/$entryFile');
    final js = (await env.readTextFile('${app.dir}/$entryFile')).getOrThrow();
    final storage = await _readStorage();
    final config = JsRuntimeConfig(
      widgetId: app.id,
      initialTheme: initialTheme,
      initialStorage: storage,
      hostBootstrapJs: _faBootstrapJsFor(hostLocale),
      onRender: (t) => tree.value = t,
      onSetTitle: (_) {},
      onStorageUpdate: _persistStorage,
      onLog: _onLog,
      isPermissionAllowed: _isAllowed,
      onResolveReady: (resolve) => _resolve = resolve,
      fetchHandler: _fetch,
      loadAssetHandler: _loadAsset,
      execHandler: _exec,
      // The dispatcher singleton (cube for primitives/OBJ, flame_3d for
      // GLB/GLTF) — shared with the renderer's `js3dHost`, which resolves
      // the same per-sceneId controllers the bridge mutates.
      js3dHost: createJs3dHost(),
    );
    final engine = JsWidgetEngine(config: config);
    _engine = engine;
    await engine.run(js);
  }

  Future<void> callEvent(String actionId, [Map<String, dynamic>? payload]) {
    final engine = _engine;
    if (engine == null) return Future.value();
    return engine.callEvent(actionId, payload);
  }

  /// Delivers a fire-and-forget host event to the app's bootstrap listeners
  /// (`jsr.scene3d.onTap` raycast results, keyboard) — no-op before [start]
  /// completes. See [JsWidgetEngine.dispatchHostEvent].
  void dispatchHostEvent(String target, Map<String, dynamic> payload) {
    _engine?.dispatchHostEvent(target, payload);
  }

  /// Pushes a new `jsr.theme` map into the running app; the JS side replaces
  /// `jsr.theme` and invokes `jsr._onThemeChange(theme)` when the app
  /// subscribed. No-op before [start] completes.
  Future<void> updateTheme(Map<String, dynamic> theme) {
    _engine?.updateTheme(theme);
    return Future.value();
  }

  /// Disposes the engine and releases its native JS context — serialized
  /// with every other engine's start/dispose (see [_lifecycle]).
  Future<void> dispose() => _guardLifecycle(() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.dispose();
    tree.dispose();
    backHandlerRegistered.dispose();
  });

  // --- storage persistence -------------------------------------------------

  String get _storagePath => '${app.dir}/storage.json';

  Future<Map<String, dynamic>> _readStorage() async {
    final raw = await env.readTextFile(_storagePath);
    final text = raw.valueOrNull;
    if (text != null) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        // Corrupt storage — start fresh.
      }
    }
    return {};
  }

  void _persistStorage(Map<String, dynamic> storage) {
    unawaited(env.writeFile(_storagePath, jsonEncode(storage)));
  }

  // --- permission gates ----------------------------------------------------
  //
  // Every capability is allowed at the bootstrap level; the handlers below
  // enforce permissions themselves so the JS side gets an ACTIONABLE error
  // ("network permission is disabled for X") instead of the package's
  // generic rejection.

  bool _isAllowed(String capability) => true;

  // --- jsr.fetchJson ---------------------------------------------------------

  Future<void> _fetch(
    String id,
    String url,
    String method,
    Map<String, String> headers,
  ) async {
    if (!permissions.network) {
      _resolve?.call(id, {'__error': _denied('network')});
      return;
    }
    try {
      final uri = Uri.parse(url);
      final response = switch (method.toUpperCase()) {
        'POST' => await http.post(uri, headers: headers),
        _ => await http.get(uri, headers: headers),
      };
      _resolve?.call(id, jsonDecode(response.body));
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  // --- jsr.loadAsset ---------------------------------------------------------

  Future<void> _loadAsset(String id, String path) async {
    try {
      _resolve?.call(
        id,
        (await env.readTextFile('${app.dir}/$path')).getOrThrow(),
      );
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  // --- jsr.exec + the jsr.fa bridge ------------------------------------------

  /// The fa bootstrap with the host locale baked in: `jsr.locale` is set
  /// before any app code runs (theme pushes only cover `jsr.theme`).
  static String _faBootstrapJsFor(String locale) {
    final safe = locale.replaceAll("'", '');
    return "jsr.locale = '$safe';\n$_faBootstrapJs";
  }

  static const String _faBootstrapJs = '''
jsr.fa = {
  call: function(method, args) {
    return jsr.exec(JSON.stringify({fa: method, args: args || {}}));
  },
  llm: function(prompt) { return jsr.fa.call('llm', {prompt: prompt}); },
  homekit: function(action, args) { return jsr.fa.call('homekit.' + action, args); },
  health: function(action, args) { return jsr.fa.call('health.' + action, args); },
  contacts: function(action, args) { return jsr.fa.call('contacts.' + action, args); },
  calendar: function(args) { return jsr.fa.call('calendar.events', args); },
};
jsr.fa.calendar.create = function(args) { return jsr.fa.call('calendar.create', args); };
jsr.fa.calendar.update = function(args) { return jsr.fa.call('calendar.update', args); };
jsr.fa.calendar.delete = function(args) { return jsr.fa.call('calendar.delete', args); };
jsr.fa.contacts.search = function(args) { return jsr.fa.call('contacts.search', args); };
jsr.fa.contacts.create = function(args) { return jsr.fa.call('contacts.create', args); };
jsr.fa.contacts.update = function(args) { return jsr.fa.call('contacts.update', args); };
jsr.fa.contacts.delete = function(args) { return jsr.fa.call('contacts.delete', args); };
jsr.fa.contacts.call = function(args) { return jsr.fa.call('contacts.call', args); };
jsr.fa.contacts.sms = function(args) { return jsr.fa.call('contacts.sms', args); };
jsr.fa.health.summary = function(args) { return jsr.fa.call('health.summary', args); };
// Home control (iOS HomeKit), gated on the `homekit` manifest flag. The
// legacy jsr.fa.homekit(action, args) form above keeps working — its
// actions route to the same backend.
jsr.fa.home = {
  homes: function() { return jsr.fa.call('home.homes', {}); },
  rooms: function(args) { return jsr.fa.call('home.rooms', args); },
  list: function(args) { return jsr.fa.call('home.list', args); },
  read: function(args) { return jsr.fa.call('home.read', args); },
  write: function(args) { return jsr.fa.call('home.write', args); },
  scenes: function(args) { return jsr.fa.call('home.scenes', args); },
  executeScene: function(args) { return jsr.fa.call('home.executeScene', args); },
  setPower: function(args) { return jsr.fa.call('home.setPower', args); },
  setBrightness: function(args) { return jsr.fa.call('home.setBrightness', args); },
  setTemperature: function(args) { return jsr.fa.call('home.setTemperature', args); },
};

// Microphone capture + speech-to-text, gated on the `microphone` manifest
// flag. record({seconds}) → {path, durationMs, sampleRate};
// transcribe({path}) → {text}.
jsr.fa.asr = {
  record: function(args) { return jsr.fa.call('asr.record', args); },
  stop: function() { return jsr.fa.call('asr.stop', {}); },
  transcribe: function(args) { return jsr.fa.call('asr.transcribe', args); },
};

// Local notifications, gated on the `notifications` manifest flag.
// schedule({title, body, delaySeconds}) → {id}; cancel({id}) →
// {cancelled: true}.
jsr.fa.notify = {
  schedule: function(args) { return jsr.fa.call('notify.schedule', args); },
  cancel: function(args) { return jsr.fa.call('notify.cancel', args); },
};

// Media generation (image / TTS / music / video) + video reading, gated on
// the `media` manifest flag. The generation methods resolve with
// {path, bytes, detail}: the file is saved in the sandbox generated/
// folder — reference it as file:<path> in image/audio nodes. readVideo
// resolves with {description} (frames never leave the host).
jsr.fa.media = {
  generateImage: function(args) { return jsr.fa.call('media.generateImage', args); },
  speak: function(args) { return jsr.fa.call('media.speak', args); },
  generateMusic: function(args) { return jsr.fa.call('media.generateMusic', args); },
  generateVideo: function(args) { return jsr.fa.call('media.generateVideo', args); },
  readVideo: function(args) { return jsr.fa.call('media.readVideo', args); },
};

// Host keys (API credentials the user saved in Fa), gated on the `keys`
// manifest flag. list() → {keys: [names]} — NAMES ONLY; get(name) →
// {name, value} for one exact name; request(name, reason) opens the host's
// native secret prompt and resolves {name, value} (rejects when the user
// declines). Apps must use these instead of hardcoding keys.
jsr.fa.keys = {
  list: function() { return jsr.fa.call('keys.list', {}); },
  get: function(name) { return jsr.fa.call('keys.get', {name: name}); },
  request: function(name, reason) { return jsr.fa.call('keys.request', {name: name, reason: reason}); },
};

// Multi-turn + streaming LLM calls. Stream deltas cannot cross the bridge as
// a function reference, so the host pushes reserved 'llm.delta' events (see
// the onEvent wrapper below) carrying the ACCUMULATED partial text; the
// promise resolves with the full reply.
jsr._llmStreams = {};
jsr.fa.llm.chat = function(messages) { return jsr.fa.call('llm.chat', {messages: messages}); };
jsr.fa.llm.stream = function(messages, onDelta) {
  var streamId = 'llm-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  if (typeof onDelta === 'function') jsr._llmStreams[streamId] = onDelta;
  return jsr.fa.call('llm.stream', {messages: messages, stream: streamId}).then(function(text) {
    delete jsr._llmStreams[streamId];
    return text;
  }, function(error) {
    delete jsr._llmStreams[streamId];
    throw error;
  });
};
jsr._dispatchLlmDelta = function(payload) {
  var handler = payload && jsr._llmStreams[payload.stream];
  if (handler) {
    try { handler(payload.text); } catch (e) { console.error('jsr.fa.llm.stream onDelta: ' + e); }
  }
};

// Back-navigation contract: the host forwards route-back attempts (iOS edge
// swipe, Android system back, app-bar arrow) as a reserved 'back' event. An
// app that assigned jsr.onBack may consume it (return true) for internal
// navigation; anything else lets the host close the app.
jsr._onBackFn = null;
Object.defineProperty(jsr, 'onBack', {
  configurable: true,
  get: function() { return jsr._onBackFn; },
  set: function(fn) {
    jsr._onBackFn = (typeof fn === 'function') ? fn : null;
    jsr.fa.call('back.handler', {registered: jsr._onBackFn !== null});
  },
});
(function() {
  var baseOnEvent = jsr.onEvent;
  jsr.onEvent = function(fn) {
    baseOnEvent(function(actionId, payload) {
      if (actionId === 'llm.delta') {
        jsr._dispatchLlmDelta(payload);
        return;
      }
      if (actionId === 'back') {
        var consumed = false;
        if (jsr._onBackFn !== null) {
          try { consumed = jsr._onBackFn() === true; }
          catch (e) { console.error('jsr.onBack: ' + e); }
        }
        if (!consumed) jsr.fa.call('back.close');
        return;
      }
      fn(actionId, payload);
    });
  };
  // Fallback so llm.stream deltas land even when the app never registers an
  // event handler; an app registration replaces this via the wrapper above.
  baseOnEvent(function(actionId, payload) {
    if (actionId === 'llm.delta') jsr._dispatchLlmDelta(payload);
  });
})();
''';

  Future<void> _exec(String id, String cmd) async {
    // The jsr.fa bridge rides on exec with a JSON envelope.
    if (cmd.startsWith('{')) {
      try {
        final decoded = jsonDecode(cmd);
        if (decoded is Map<String, dynamic> && decoded['fa'] is String) {
          await _faCall(
            id,
            decoded['fa'] as String,
            (decoded['args'] as Map?)?.cast<String, Object?>() ?? const {},
          );
          return;
        }
      } on FormatException {
        // Not a bridge call — fall through to shell handling.
      }
    }
    if (!_isShellAllowed(cmd)) {
      _resolve?.call(id, {'__error': _denied('this command')});
      return;
    }
    final result = await env.exec(cmd);
    final value = result.valueOrNull;
    if (value == null) {
      _resolve?.call(id, {'__error': '${result.errorOrNull}'});
      return;
    }
    _resolve?.call(id, {
      'stdout': value.stdout,
      'stderr': value.stderr,
      'exitCode': value.exitCode,
    });
  }

  bool _isShellAllowed(String cmd) {
    final name = cmd.trim().split(RegExp(r'\s+')).first;
    return permissions.allowedCommands.contains(name);
  }

  Future<void> _faCall(
    String id,
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      if (method == 'llm' || method == 'llm.chat' || method == 'llm.stream') {
        if (!permissions.llm) throw StateError(_denied('llm'));
        final handler = llmHandler;
        if (handler == null) {
          throw StateError(
            'no LLM is connected — connect a model in the Fa settings first',
          );
        }
        final messages = method == 'llm'
            ? [(role: 'user', content: (args['prompt'] ?? '').toString())]
            : _parseLlmMessages(args['messages']);
        if (method == 'llm.stream') {
          // Deltas cross back as reserved 'llm.delta' events (see
          // _faBootstrapJs) carrying the accumulated partial text.
          final streamId = (args['stream'] ?? '').toString();
          final partial = StringBuffer();
          _resolve?.call(
            id,
            await handler(
              messages,
              onDelta: (delta) {
                partial.write(delta);
                final engine = _engine;
                if (engine == null) return;
                unawaited(
                  engine.callEvent('llm.delta', {
                    'stream': streamId,
                    'text': partial.toString(),
                  }),
                );
              },
            ),
          );
          return;
        }
        _resolve?.call(id, await handler(messages));
        return;
      }
      if (method == 'calendar.events') {
        _resolve?.call(id, await _calendarEvents(args));
        return;
      }
      if (method == 'calendar.create') {
        _resolve?.call(id, await _calendarCreate(args));
        return;
      }
      if (method == 'calendar.update') {
        _resolve?.call(id, await _calendarUpdate(args));
        return;
      }
      if (method == 'calendar.delete') {
        _resolve?.call(id, await _calendarDelete(args));
        return;
      }
      if (method == 'contacts.search') {
        _resolve?.call(id, await _contactsSearch(args));
        return;
      }
      if (method == 'contacts.create') {
        _resolve?.call(id, await _contactsCreate(args));
        return;
      }
      if (method == 'contacts.update') {
        _resolve?.call(id, await _contactsUpdate(args));
        return;
      }
      if (method == 'contacts.delete') {
        _resolve?.call(id, await _contactsDelete(args));
        return;
      }
      if (method == 'contacts.call') {
        _resolve?.call(id, await _contactsCall(args));
        return;
      }
      if (method == 'contacts.sms') {
        _resolve?.call(id, await _contactsSms(args));
        return;
      }
      if (method == 'health.summary') {
        _resolve?.call(id, await _healthSummary(args));
        return;
      }
      if (method == 'asr.record') {
        _resolve?.call(id, await _asrRecord(args));
        return;
      }
      if (method == 'asr.stop') {
        final signal = _asrStopSignal;
        if (signal != null && !signal.isCompleted) signal.complete();
        _resolve?.call(id, {'stopped': signal != null});
        return;
      }
      if (method == 'asr.transcribe') {
        _resolve?.call(id, await _asrTranscribe(args));
        return;
      }
      if (method == 'notify.schedule') {
        _resolve?.call(id, await _notifySchedule(args));
        return;
      }
      if (method == 'notify.cancel') {
        _resolve?.call(id, await _notifyCancel(args));
        return;
      }
      if (method == 'media.generateImage') {
        _resolve?.call(id, await _mediaGenerateImage(args));
        return;
      }
      if (method == 'media.speak') {
        _resolve?.call(id, await _mediaSpeak(args));
        return;
      }
      if (method == 'media.generateMusic') {
        _resolve?.call(id, await _mediaGenerateMusic(args));
        return;
      }
      if (method == 'media.generateVideo') {
        _resolve?.call(id, await _mediaGenerateVideo(args));
        return;
      }
      if (method == 'media.readVideo') {
        _resolve?.call(id, await _mediaReadVideo(args));
        return;
      }
      if (method == 'keys.list') {
        _resolve?.call(id, _keysList());
        return;
      }
      if (method == 'keys.get') {
        _resolve?.call(id, _keysGet(args));
        return;
      }
      if (method == 'keys.request') {
        _resolve?.call(id, await _keysRequest(args));
        return;
      }
      // Home control (iOS HomeKit). `home.*` is the current surface; the
      // legacy `homekit.<action>` calls route to the same handlers.
      final homeAction = switch (method) {
        'home.homes' || 'homekit.homes' => 'homes',
        'home.rooms' || 'homekit.rooms' => 'rooms',
        'home.list' || 'homekit.list' || 'homekit.listDevices' => 'list',
        'home.read' || 'homekit.read' => 'read',
        'home.write' || 'homekit.write' => 'write',
        'home.scenes' || 'homekit.scenes' => 'scenes',
        'home.executeScene' || 'homekit.executeScene' => 'executeScene',
        'home.setPower' || 'homekit.setPower' => 'setPower',
        'home.setBrightness' || 'homekit.setBrightness' => 'setBrightness',
        'home.setTemperature' || 'homekit.setTemperature' => 'setTemperature',
        _ => null,
      };
      if (homeAction != null) {
        _resolve?.call(id, await _homeCall(homeAction, args));
        return;
      }
      // Back-navigation contract (see _faBootstrapJs): the app reports its
      // jsr.onBack registration, and asks the host to close when a back
      // event went unconsumed. Neither is permission-gated.
      if (method == 'back.handler') {
        backHandlerRegistered.value = args['registered'] == true;
        _resolve?.call(id, true);
        return;
      }
      if (method == 'back.close') {
        onCloseRequested?.call();
        _resolve?.call(id, true);
        return;
      }
      final prefix = method.split('.').first;
      final granted = switch (prefix) {
        'homekit' => permissions.homekit,
        'health' => permissions.health,
        'contacts' => permissions.contacts,
        _ => false,
      };
      if (!granted) throw StateError(_denied(prefix));
      final handler = platformHandler;
      if (handler == null) {
        throw StateError(
          '$prefix bridge is not available on this platform yet',
        );
      }
      _resolve?.call(id, await handler(method, args));
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  /// `jsr.fa.calendar({date, days})` → `{events: [...]}` — system calendar
  /// access, gated on the `calendar` permission.
  Future<Map<String, Object?>> _calendarEvents(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final range = calendarRange(
      date: args['date']?.toString(),
      days: (args['days'] as num?)?.toInt(),
    );
    final events = await api.events(start: range.start, end: range.end);
    return {
      'events': [
        for (final event in events)
          {
            'id': event.id,
            'title': event.title,
            'startMs': event.start.millisecondsSinceEpoch,
            'endMs': event.end.millisecondsSinceEpoch,
            'allDay': event.allDay,
            if (event.calendar != null) 'calendar': event.calendar,
            if (event.location != null) 'location': event.location,
            if (event.notes != null) 'notes': event.notes,
            if (event.url != null) 'url': event.url,
            if (event.alarms != null) 'alarms': event.alarms,
            if (event.recurrence case final rule?)
              'recurrence': {
                'frequency': rule.frequency,
                'interval': rule.interval,
                if (rule.daysOfWeek != null) 'daysOfWeek': rule.daysOfWeek,
                if (rule.daysOfMonth != null) 'daysOfMonth': rule.daysOfMonth,
                if (rule.until != null) 'until': calendarDayLabel(rule.until!),
                if (rule.count != null) 'count': rule.count,
              },
          },
      ],
    };
  }

  /// `jsr.fa.calendar.create({title, date, startHour, endHour, allDay,
  /// location, notes, url, calendar, alarms, recurrence})` → `{id}` —
  /// same `calendar` permission gate.
  Future<Map<String, Object?>> _calendarCreate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) throw StateError('title is required');
    final slot = calendarSlot(
      date: args['date']?.toString(),
      startHour: args['startHour'] as num?,
      endHour: args['endHour'] as num?,
      allDay: args['allDay'] == true,
    );
    final id = await api.createEvent(
      title: title,
      start: slot.start,
      end: slot.end,
      allDay: slot.allDay,
      calendar: args['calendar']?.toString(),
      location: args['location']?.toString(),
      notes: args['notes']?.toString(),
      url: args['url']?.toString(),
      alarms: parseCalendarAlarms(args['alarms']),
      recurrence: parseCalendarRecurrence(args['recurrence']).rule,
    );
    return {'id': id};
  }

  /// `jsr.fa.calendar.update({id, ...same fields, span})` → `{updated: true}`;
  /// only the supplied fields change (`recurrence: 'none'`/`{}` removes the
  /// rule, `alarms: []` clears the reminders).
  Future<Map<String, Object?>> _calendarUpdate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    final hasSlot =
        args.containsKey('startHour') ||
        args.containsKey('endHour') ||
        args.containsKey('allDay');
    final slot = hasSlot
        ? calendarSlot(
            date: args['date']?.toString(),
            startHour: args['startHour'] as num?,
            endHour: args['endHour'] as num?,
            allDay: args['allDay'] == true,
          )
        : null;
    final recurrence = parseCalendarRecurrence(args['recurrence']);
    await api.updateEvent(
      id: id,
      title: args['title']?.toString(),
      start: slot?.start,
      end: slot?.end,
      allDay: slot?.allDay,
      calendar: args['calendar']?.toString(),
      location: args['location']?.toString(),
      notes: args['notes']?.toString(),
      url: args['url']?.toString(),
      alarms: parseCalendarAlarms(args['alarms']),
      recurrence: recurrence.rule,
      removeRecurrence: recurrence.remove,
      span: parseCalendarSpan(args['span']),
    );
    return {'updated': true};
  }

  /// `jsr.fa.calendar.delete({id, span})` → `{deleted: true}`.
  Future<Map<String, Object?>> _calendarDelete(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    await api.deleteEvent(id: id, span: parseCalendarSpan(args['span']));
    return {'deleted': true};
  }

  /// The permission gate every `jsr.fa.calendar*` bridge call shares:
  /// the `calendar` permission, a platform backend, and OS access.
  Future<CalendarApi> _gatedCalendar() async {
    if (!permissions.calendar) throw StateError(_denied('calendar'));
    final api = calendar ?? createCalendarService();
    if (!await api.isAvailable) {
      throw StateError('calendar is not available on this platform');
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'calendar access was denied — enable it in the system privacy '
        'settings (Privacy & Security → Calendars)',
      );
    }
    return api;
  }

  /// `jsr.fa.contacts.search({query?, limit?, offset?})` → `{contacts: [...]}`
  /// — system contacts access, gated on the `contacts` permission. An empty
  /// query lists the whole address book, paged.
  Future<Map<String, Object?>> _contactsSearch(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedContacts();
    final query = (args['query'] ?? '').toString().trim();
    final limit = args['limit'] is num ? (args['limit'] as num).toInt() : 200;
    final offset = args['offset'] is num ? (args['offset'] as num).toInt() : 0;
    final found = await api.searchContacts(
      query: query,
      limit: limit,
      offset: offset,
    );
    return {
      'contacts': [for (final contact in found) _contactMap(contact)],
    };
  }

  static Map<String, Object?> _contactMap(Contact contact) => {
    'id': contact.id,
    'name': contact.name,
    'phones': contact.phones,
    'emails': contact.emails,
  };

  /// `jsr.fa.contacts.create({name, phones?, emails?, note?})` → `{id}` —
  /// same `contacts` permission gate.
  Future<Map<String, Object?>> _contactsCreate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedContacts();
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) throw StateError('name is required');
    final id = await api.createContact(
      name: name,
      phones: _stringListArg(args, 'phones'),
      emails: _stringListArg(args, 'emails'),
      note: args['note']?.toString(),
    );
    return {'id': id};
  }

  /// `jsr.fa.contacts.update({id, name?, phones?, emails?, note?})` →
  /// `{updated: true}`; a supplied phones/emails list REPLACES the
  /// existing entries.
  Future<Map<String, Object?>> _contactsUpdate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedContacts();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    await api.updateContact(
      id: id,
      name: args['name']?.toString(),
      phones: _stringListArg(args, 'phones'),
      emails: _stringListArg(args, 'emails'),
      note: args['note']?.toString(),
    );
    return {'updated': true};
  }

  /// `jsr.fa.contacts.delete({id})` → `{deleted: true}`.
  Future<Map<String, Object?>> _contactsDelete(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedContacts();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    await api.deleteContact(id: id);
    return {'deleted': true};
  }

  /// `jsr.fa.contacts.call({phone} | {id})` → `{calling: phone}` — opens
  /// a `tel:` URL with the contact's number.
  Future<Map<String, Object?>> _contactsCall(Map<String, Object?> args) async {
    final api = await _gatedContacts();
    final phone = await _contactsPhone(api, args);
    if (!await api.openUrl('tel:$phone')) {
      throw StateError('could not open the dialer for $phone');
    }
    return {'calling': phone};
  }

  /// `jsr.fa.contacts.sms({phone, text} | {id, text})` → `{texting:
  /// phone}` — opens an `sms:` URL pre-filled with the message.
  Future<Map<String, Object?>> _contactsSms(Map<String, Object?> args) async {
    final api = await _gatedContacts();
    final text = (args['text'] ?? '').toString().trim();
    if (text.isEmpty) throw StateError('text is required');
    final phone = await _contactsPhone(api, args);
    final url = 'sms:$phone?&body=${Uri.encodeComponent(text)}';
    if (!await api.openUrl(url)) {
      throw StateError('could not open the Messages app for $phone');
    }
    return {'texting': phone};
  }

  /// The target phone for contacts.call/sms: the explicit `phone` arg, or
  /// the first number of the contact with `id`.
  Future<String> _contactsPhone(
    ContactApi api,
    Map<String, Object?> args,
  ) async {
    final phone = (args['phone'] ?? '').toString().trim();
    if (phone.isNotEmpty) return phone;
    final id = (args['id'] ?? '').toString().trim();
    if (id.isEmpty) throw StateError('phone (or id) is required');
    for (final contact in await api.searchContacts(query: '')) {
      if (contact.id == id) {
        if (contact.phones.isEmpty) {
          throw StateError('this contact has no phone number');
        }
        return contact.phones.first;
      }
    }
    throw StateError(
      'no contact with id "$id" — search first, then pass phone',
    );
  }

  /// Reads a string-list bridge argument: a JSON list, or a single
  /// comma-separated string. Null when absent/empty.
  static List<String>? _stringListArg(Map<String, Object?> args, String key) {
    final raw = args[key];
    final items = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final text = item.toString().trim();
        if (text.isNotEmpty) items.add(text);
      }
    } else if (raw != null) {
      for (final part in raw.toString().split(',')) {
        final text = part.trim();
        if (text.isNotEmpty) items.add(text);
      }
    }
    return items.isEmpty ? null : items;
  }

  /// The permission gate every `jsr.fa.contacts.*` bridge call shares:
  /// the `contacts` permission, a platform backend, and OS access.
  Future<ContactApi> _gatedContacts() async {
    if (!permissions.contacts) throw StateError(_denied('contacts'));
    final api = contacts ?? createContactService();
    if (!await api.isAvailable) {
      throw StateError('contacts are not available on this platform');
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'contacts access was denied — enable it in the system privacy '
        'settings (Privacy & Security → Contacts)',
      );
    }
    return api;
  }

  /// `jsr.fa.health.summary({days?})` → `{steps, restingHeartRate,
  /// sleepHours}` (each a list of {date, value} day entries) — read-only
  /// health data, gated on the `health` permission.
  Future<Map<String, Object?>> _healthSummary(Map<String, Object?> args) async {
    final api = await _gatedHealth();
    final summary = await api.summary(days: healthDays(args['days'] as num?));
    List<Map<String, Object?>> entries(List<HealthSample> samples) => [
      for (final sample in samples)
        {'date': sample.date, 'value': sample.value},
    ];
    return {
      'steps': entries(summary.steps),
      'restingHeartRate': entries(summary.restingHeartRate),
      'sleepHours': entries(summary.sleepHours),
    };
  }

  /// The permission gate every `jsr.fa.health.*` bridge call shares:
  /// the `health` permission, a platform backend, and OS access.
  Future<HealthApi> _gatedHealth() async {
    if (!permissions.health) throw StateError(_denied('health'));
    final api = health ?? createHealthService();
    if (!await api.isAvailable) {
      throw StateError('health data is not available on this platform');
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'health access was denied — enable it in the Health app '
        '(profile picture → Apps → Fa)',
      );
    }
    return api;
  }

  /// `jsr.fa.home.*` (and the legacy `homekit.<action>`) bridge calls,
  /// gated on the `homekit` permission. Actions: `homes` → `{homes: [{id,
  /// name, primary, roomCount, accessoryCount}]}`, `rooms` {homeId?} →
  /// `{rooms: [{id, name, homeName, accessoryCount}]}`, `list` {homeId?,
  /// roomId?} → `{accessories: [...]}` (each with the flat isOn/brightness/
  /// targetTemperature conveniences plus a `services` array of {type, name,
  /// characteristics: [{type, value?, readable, writable}]}), `read` {id} →
  /// `{accessory: ...}` with fresh values, `write` {id, type, value} →
  /// `{written: true}` (ANY writable characteristic by HomeKit type
  /// string), `scenes` {homeId?} → `{scenes: [{id, name, homeName,
  /// actionCount, executing}]}`, `executeScene` {id} → `{executed: true}`,
  /// and the thin aliases `setPower` {id, on}, `setBrightness` {id, value},
  /// `setTemperature` {id, celsius}. Every write accepts optional
  /// {name, room} narrowing for duplicate bridge ids (see
  /// [HomeApi.setPower]). List sizes and failures are mirrored
  /// into [AppLog] under the `home` tag.
  Future<Map<String, Object?>> _homeCall(
    String action,
    Map<String, Object?> args,
  ) async {
    final api = await _gatedHome();
    try {
      switch (action) {
        case 'homes':
          final homes = await api.listHomes();
          AppLog.i('home', 'bridge homes → ${homes.length}');
          return {
            'homes': [
              for (final home in homes)
                {
                  'id': home.id,
                  'name': home.name,
                  'primary': home.primary,
                  'roomCount': home.roomCount,
                  'accessoryCount': home.accessoryCount,
                },
            ],
          };
        case 'rooms':
          final rooms = await api.listRooms(
            homeId: _optionalString(args, 'homeId'),
          );
          AppLog.i('home', 'bridge rooms → ${rooms.length}');
          return {
            'rooms': [
              for (final room in rooms)
                {
                  'id': room.id,
                  'name': room.name,
                  'homeName': room.homeName,
                  'accessoryCount': room.accessoryCount,
                },
            ],
          };
        case 'list':
          final accessories = await api.listAccessories(
            homeId: _optionalString(args, 'homeId'),
            roomId: _optionalString(args, 'roomId'),
          );
          AppLog.i('home', 'bridge list → ${accessories.length} accessories');
          return {
            'accessories': [
              for (final accessory in accessories) _homeAccessoryMap(accessory),
            ],
          };
        case 'read':
          return {
            'accessory': _homeAccessoryMap(
              await api.readAccessory(id: _requiredId(args)),
            ),
          };
        case 'write':
          final id = _requiredId(args);
          final type = (args['type'] ?? '').toString();
          if (type.isEmpty) throw StateError('type is required');
          final value = args['value'];
          if (value == null) throw StateError('value is required');
          await api.writeCharacteristic(
            id: id,
            type: type,
            value: value,
            name: _optionalString(args, 'name'),
            room: _optionalString(args, 'room'),
          );
          return {'written': true};
        case 'scenes':
          final scenes = await api.listScenes(
            homeId: _optionalString(args, 'homeId'),
          );
          AppLog.i('home', 'bridge scenes → ${scenes.length}');
          return {
            'scenes': [
              for (final scene in scenes)
                {
                  'id': scene.id,
                  'name': scene.name,
                  'homeName': scene.homeName,
                  'actionCount': scene.actionCount,
                  'executing': scene.executing,
                },
            ],
          };
        case 'executeScene':
          await api.executeScene(id: _requiredId(args));
          return {'executed': true};
        case 'setPower':
          final id = _requiredId(args);
          final on = args['on'] == true;
          await api.setPower(
            id: id,
            on: on,
            name: _optionalString(args, 'name'),
            room: _optionalString(args, 'room'),
          );
          return {'on': on};
        case 'setBrightness':
          final id = _requiredId(args);
          final value = homeBrightness(args['value'] as num?);
          await api.setBrightness(
            id: id,
            value: value,
            name: _optionalString(args, 'name'),
            room: _optionalString(args, 'room'),
          );
          return {'brightness': value};
        case 'setTemperature':
          final id = _requiredId(args);
          final celsius = homeTemperature(args['celsius'] as num?);
          await api.setTargetTemperature(
            id: id,
            celsius: celsius,
            name: _optionalString(args, 'name'),
            room: _optionalString(args, 'room'),
          );
          return {'temperature': celsius};
        default:
          throw StateError('unknown home action "$action"');
      }
    } on Object catch (error) {
      AppLog.i('home', 'bridge $action failed: $error');
      rethrow;
    }
  }

  /// One accessory as the bridge map: the flat conveniences plus the full
  /// service/characteristic breakdown.
  Map<String, Object?> _homeAccessoryMap(HomeAccessory accessory) => {
    'id': accessory.id,
    'name': accessory.name,
    'room': accessory.room,
    'homeName': accessory.homeName,
    'category': accessory.category,
    'reachable': accessory.reachable,
    if (accessory.isOn != null) 'isOn': accessory.isOn,
    if (accessory.brightness != null) 'brightness': accessory.brightness,
    if (accessory.targetTemperature != null)
      'targetTemperature': accessory.targetTemperature,
    'services': [
      for (final service in accessory.services)
        {
          'type': service.type,
          'name': service.name,
          'characteristics': [
            for (final characteristic in service.characteristics)
              {
                'type': characteristic.type,
                if (characteristic.value != null) 'value': characteristic.value,
                'readable': characteristic.readable,
                'writable': characteristic.writable,
              },
          ],
        },
    ],
  };

  /// The required `id` argument every single-accessory home call shares.
  String _requiredId(Map<String, Object?> args) {
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    return id;
  }

  /// An optional string argument, null when missing or empty.
  String? _optionalString(Map<String, Object?> args, String key) {
    final value = (args[key] ?? '').toString();
    return value.isEmpty ? null : value;
  }

  /// The permission gate every `jsr.fa.home.*` bridge call shares: the
  /// `homekit` permission, a platform backend, and OS access.
  Future<HomeApi> _gatedHome() async {
    if (!permissions.homekit) throw StateError(_denied('homekit'));
    final api = home ?? createHomeService();
    if (!await api.isAvailable) {
      throw StateError('home control is not available on this platform');
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'home access was denied — enable it in the system privacy '
        'settings (Privacy & Security → HomeKit)',
      );
    }
    return api;
  }

  /// In-flight microphone recording's early-stop signal: `asr.stop`
  /// completes it so a pending `asr.record` resolves immediately instead
  /// of waiting out its max-seconds guard.
  Completer<void>? _asrStopSignal;

  /// `jsr.fa.asr.record({seconds?})` → `{path, durationMs, sampleRate}` —
  /// records `seconds` (1–[asrMaxRecordSeconds], default 10) from the
  /// microphone into a temporary .m4a, gated on the `microphone`
  /// permission.
  Future<Map<String, Object?>> _asrRecord(Map<String, Object?> args) async {
    final api = await _gatedAsr();
    if (_asrStopSignal != null) {
      throw StateError('a recording is already in progress');
    }
    final seconds = asrRecordSeconds(args['seconds'] as num?);
    await api.startRecording();
    final stop = Completer<void>();
    _asrStopSignal = stop;
    try {
      // The max-seconds guard OR an explicit jsr.fa.asr.stop() — whichever
      // comes first — ends the take.
      await Future.any<void>([
        Future<void>.delayed(Duration(seconds: seconds)),
        stop.future,
      ]);
    } finally {
      if (identical(_asrStopSignal, stop)) _asrStopSignal = null;
    }
    final recording = await api.stopRecording();
    return {
      'path': recording.path,
      'durationMs': recording.durationMs,
      'sampleRate': recording.sampleRate,
    };
  }

  /// `jsr.fa.asr.transcribe({path})` → `{text}` — transcribes a recording
  /// (or any readable audio file) through the configured OpenAI-compatible
  /// endpoint; without one the call answers with an actionable error.
  Future<Map<String, Object?>> _asrTranscribe(Map<String, Object?> args) async {
    final api = await _gatedAsr();
    final path = (args['path'] ?? '').toString();
    if (path.isEmpty) throw StateError('path is required');
    final transcriber = asrTranscriber;
    if (transcriber == null) throw StateError(asrNoEndpointMessage);
    final bytes = await api.readRecording(path);
    final filename = path.split(RegExp(r'[/\\]')).last;
    return {
      'text': await transcriber.transcribe(bytes: bytes, filename: filename),
    };
  }

  /// The permission gate every `jsr.fa.asr.*` bridge call shares: the
  /// `microphone` permission, a platform backend, and OS access.
  Future<AsrApi> _gatedAsr() async {
    if (!permissions.microphone) throw StateError(_denied('microphone'));
    final api = asr ?? createAsrService();
    if (!await api.isAvailable) {
      throw StateError(
        'microphone recording is not available on this platform',
      );
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'microphone access was denied — enable it in the system privacy '
        'settings (Privacy & Security → Microphone)',
      );
    }
    return api;
  }

  /// `jsr.fa.notify.schedule({title, body?, delaySeconds?})` → `{id}` —
  /// schedules a local notification (immediate, or after `delaySeconds`;
  /// never repeating), gated on the `notifications` permission.
  Future<Map<String, Object?>> _notifySchedule(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedNotify();
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) throw StateError('title is required');
    final delay = (args['delaySeconds'] as num?)?.toDouble() ?? 0;
    if (delay < 0) throw StateError('delaySeconds must be >= 0');
    final id = await api.schedule(
      title: title,
      body: args['body']?.toString(),
      delaySeconds: delay,
    );
    return {'id': id};
  }

  /// `jsr.fa.notify.cancel({id})` → `{cancelled: true}`.
  Future<Map<String, Object?>> _notifyCancel(Map<String, Object?> args) async {
    final api = await _gatedNotify();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    await api.cancel(id: id);
    return {'cancelled': true};
  }

  /// The permission gate every `jsr.fa.notify.*` bridge call shares: the
  /// `notifications` permission, a platform backend, and OS access.
  Future<NotifyApi> _gatedNotify() async {
    if (!permissions.notifications) throw StateError(_denied('notifications'));
    final api = notify ?? createNotifyService();
    if (!await api.isAvailable) {
      throw StateError(
        'local notifications are not available on this platform',
      );
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'notification access was denied — enable it in the system settings '
        '(System Settings → Notifications → Fa)',
      );
    }
    return api;
  }

  /// `jsr.fa.media.generateImage({prompt, size?})` → `{path, bytes,
  /// detail}` — image generation on the configured imageGeneration
  /// endpoint, gated on the `media` permission.
  Future<Map<String, Object?>> _mediaGenerateImage(
    Map<String, Object?> args,
  ) async {
    final gateway = _gatedMedia();
    final file = await gateway.generateImage(
      prompt: (args['prompt'] ?? '').toString(),
      size: args['size']?.toString(),
    );
    return file.toBridgeJson();
  }

  /// `jsr.fa.media.speak({text, voice?})` → `{path, bytes, detail}` —
  /// text-to-speech on the configured audioTts endpoint, same gate.
  Future<Map<String, Object?>> _mediaSpeak(Map<String, Object?> args) async {
    final gateway = _gatedMedia();
    final file = await gateway.speak(
      text: (args['text'] ?? '').toString(),
      voice: args['voice']?.toString(),
    );
    return file.toBridgeJson();
  }

  /// `jsr.fa.media.generateMusic({prompt, seconds?})` → `{path, bytes,
  /// detail}` — music on the configured musicGeneration endpoint, same
  /// gate.
  Future<Map<String, Object?>> _mediaGenerateMusic(
    Map<String, Object?> args,
  ) async {
    final gateway = _gatedMedia();
    final file = await gateway.generateMusic(
      prompt: (args['prompt'] ?? '').toString(),
      seconds: (args['seconds'] as num?)?.toInt(),
    );
    return file.toBridgeJson();
  }

  /// `jsr.fa.media.generateVideo({prompt, seconds?, size?})` → `{path,
  /// bytes, detail}` — video on the configured videoGeneration endpoint,
  /// same gate. Generation is asynchronous (the gateway polls the job), so
  /// the promise can take minutes to resolve.
  Future<Map<String, Object?>> _mediaGenerateVideo(
    Map<String, Object?> args,
  ) async {
    final gateway = _gatedMedia();
    final file = await gateway.generateVideo(
      prompt: (args['prompt'] ?? '').toString(),
      seconds: (args['seconds'] as num?)?.toInt(),
      size: args['size']?.toString(),
    );
    return file.toBridgeJson();
  }

  /// `jsr.fa.media.readVideo({path, frames?, question?})` → `{description}`
  /// — video understanding on the configured vision endpoint, gated on the
  /// same `media` permission. [VideoReader.describe] throws StateErrors
  /// with actionable text; they cross the bridge as the rejection reason.
  Future<Map<String, Object?>> _mediaReadVideo(
    Map<String, Object?> args,
  ) async {
    if (!permissions.media) throw StateError(_denied('media'));
    final reader = videoReader;
    if (reader == null) {
      throw StateError(
        'video reading is not available in this session — connect a model '
        'in the Fa settings first',
      );
    }
    final path = (args['path'] ?? '').toString().trim();
    if (path.isEmpty) throw StateError('path is required');
    final exists = await env.exists(path);
    if (exists.valueOrNull != true) {
      throw StateError('no such file: $path');
    }
    // The platform extractor (AVAssetImageGenerator) works on host paths;
    // the sandbox env maps the app-visible path.
    final hostPath = (await env.absolutePath(path)).valueOrNull ?? path;
    final description = await reader.describe(
      path: hostPath,
      frames: videoFramesCount(args['frames'] as num?),
      question: args['question']?.toString(),
    );
    return {'description': description};
  }

  /// The permission gate the `jsr.fa.media.*` generation calls share: the
  /// `media` permission plus a session media gateway (endpoint resolution
  /// errors come from the gateway itself, with actionable text).
  MediaGateway _gatedMedia() {
    if (!permissions.media) throw StateError(_denied('media'));
    final gateway = mediaGateway;
    if (gateway == null) {
      throw StateError(
        'media generation is not available in this session — connect a '
        'model in the Fa settings first',
      );
    }
    return gateway;
  }

  /// The permission gate the `jsr.fa.keys.list/get` calls share: the `keys`
  /// permission plus a session host-keys source.
  FaHostKeysSource _gatedKeys() {
    if (!permissions.keys) throw StateError(_denied('keys'));
    final source = keysSource;
    if (source == null) {
      throw StateError('host keys are not available in this session');
    }
    return source;
  }

  /// `jsr.fa.keys.list()` → `{keys: [...]}` — the NAMES of the host's
  /// available env keys, sorted; values never cross this call.
  Map<String, Object?> _keysList() {
    final names = _gatedKeys()().keys.toList()..sort();
    return {'keys': names};
  }

  /// `jsr.fa.keys.get({name})` → `{name, value}` — the value of ONE host
  /// env key by exact name; an unknown name is an actionable error (the
  /// caller should list first or request the key).
  Map<String, Object?> _keysGet(Map<String, Object?> args) {
    final source = _gatedKeys();
    final name = (args['name'] ?? '').toString();
    if (name.isEmpty) throw StateError('name is required');
    final value = source()[name];
    if (value == null) {
      throw StateError(
        'unknown host key "$name" — call jsr.fa.keys.list() for the '
        'available names, or jsr.fa.keys.request() to ask the user for it',
      );
    }
    return {'name': name, 'value': value};
  }

  /// `jsr.fa.keys.request({name, reason})` → `{name, value}` — opens the
  /// host's native secret prompt (the same sheet the agent's
  /// `request_secret` tool uses); a grant is persisted by the host and
  /// resolves with the value, a decline/cancel rejects.
  Future<Map<String, Object?>> _keysRequest(Map<String, Object?> args) async {
    if (!permissions.keys) throw StateError(_denied('keys'));
    final handler = keyRequestHandler;
    if (handler == null) {
      throw StateError(
        'this host cannot prompt for secrets — ask the user to add the key '
        'in the Fa settings Keys section',
      );
    }
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) throw StateError('name is required');
    var reason = (args['reason'] ?? '').toString().trim();
    if (reason.isEmpty) {
      reason = 'The app "${app.name}" asks for the $name key.';
    }
    final result = await handler(name, reason);
    if (result == null) {
      throw StateError('the user declined to provide $name');
    }
    return {'name': result.name, 'value': result.value};
  }

  /// Validates the `messages` argument of `llm.chat`/`llm.stream`:
  /// `[{role: 'user'|'assistant'|'system', content: '...'}]`.
  static List<FaLlmMessage> _parseLlmMessages(Object? raw) {
    if (raw is! List) {
      throw StateError('messages must be a list of {role, content} objects');
    }
    final messages = <FaLlmMessage>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw StateError('each message must be a {role, content} object');
      }
      final role = (entry['role'] ?? '').toString();
      if (role != 'user' && role != 'assistant' && role != 'system') {
        throw StateError(
          'unsupported message role "$role" (user/assistant/system)',
        );
      }
      messages.add((role: role, content: (entry['content'] ?? '').toString()));
    }
    if (messages.isEmpty) throw StateError('messages must not be empty');
    return messages;
  }

  String _denied(String what) =>
      '$what permission is disabled for "${app.name}" '
      '(enable it in the app permissions)';
}
