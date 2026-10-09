// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show BindingBase;
import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:fa/apps/fa_js3d_host.dart';
import 'package:fa/apps/fa_webview_host.dart';
import 'package:fa/apps/js_app_error_channel.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

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
typedef FaLlmHandler = Future<Object?> Function(
  List<FaLlmMessage> messages, {
  void Function(String delta)? onDelta,
});

/// Handler for platform bridges still without a real backend (health
/// actions other than `health.summary`). Receives the action name
/// (`health.stepsToday`, …) and args.
typedef FaPlatformHandler = Future<Object?> Function(
  String action,
  Map<String, Object?> args,
);

/// Read source for the host's merged secrets (dotenv + saved keys) behind
/// the `jsr.fa.keys.list/get` bridge calls; returns a fresh name → value
/// map on every call.
typedef FaHostKeysSource = Map<String, String> Function();

/// One `home`/`homekit` action handler: resolves the bridge map from the
/// gated [HomeApi] (see [_homeActions]).
typedef _HomeAction = Future<Map<String, Object?>> Function(
  HomeApi api,
  Map<String, Object?> args,
);

/// Theme-pack bridge behind `jsr.fa.theme.list/current/apply` (issue #169).
/// The host implements it; the apply leg ALWAYS renders a consent prompt —
/// the security model is "declarative data + user consent per apply", so
/// the interface exposes no install, no uninstall, no raw color writes.
abstract interface class FaThemeBridge {
  /// The installed packs as `{id, name, version, hasWallpaper,
  /// contrastWarnings}` descriptors.
  Future<List<Map<String, Object?>>> listPacks();

  /// The active pack's descriptor, or null for the stock Fa look.
  Future<Map<String, Object?>?> currentPack();

  /// Applies one pack by id. An unknown id throws a StateError with
  /// actionable text; a user decline resolves `{applied: false,
  /// reason: 'denied'}`; a grant resolves `{applied: true, pack: ...}`.
  Future<Map<String, Object?>> applyPack(String id);
}

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
/// - `jsr.fa.theme.list/current/apply` → [AppPermissions.theme] via
///   [FaThemeBridge]; every `apply` prompts the user for consent (issue
///   #169's declarative-only, secured theme channel)
/// - other health actions → the matching flag (stubbed until the platform
///   implementations land — a granted call answers "not available").
///
/// Live instances of one app (a launcher board tile AND the fullscreen
/// view, or several tiles) run SEPARATE engines by design — the native JS
/// context is single-viewport — but they share one logical state through
/// storage: every `jsr.storage.set` persists to `storage.json` (survives
/// restarts) AND is broadcast to the app's other live engines as a
/// reserved `state.sync` event (see [_broadcastStorageChanges]). Widgets
/// that want live sync keep their state under a reserved `__`-prefixed
/// storage key (protocol: docs in `fa_widgets/docs/state-sync.md`) —
/// durable fields plus a `rev`/`writer` guard so sibling engines adopt
/// external changes instead of fighting over them.
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
    this.themeBridge,
    this.webViewHost,
    this.onEmit,
    this.hostLocale = 'en',
    this.initialTheme = const {},
    this.errorSink,
    this.joinSiblingGroup = true,
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

  /// Theme-pack bridge behind `jsr.fa.theme.list/current/apply` (see
  /// [FaThemeBridge]); `null` answers with an actionable "not available in
  /// this session" error. The apply leg ALWAYS prompts the user — the host
  /// implementation owns the consent dialog; there is no install/uninstall
  /// bridge call by design (issue #169).
  final FaThemeBridge? themeBridge;

  /// Host for `webView` nodes; `null` (the default) uses the platform
  /// default (see [createFaWebViewHost] — a real `flutter_inappwebview`
  /// surface on iOS/Android/macOS, the renderer's placeholder elsewhere).
  /// Tests inject fakes to stay off the native plugin.
  final JsWebViewHost? webViewHost;

  /// Host sink for the shared `emit` fa bridge — dynamic messages wire it to
  /// the agent back-channel (each emit surfaces as a user message); installed
  /// apps leave it null and the bridge resolves {emitted: false}.
  final void Function(String event, Map<String, Object?> payload)? onEmit;

  /// Where captured JS errors go (gh-1164): raw runtime events forwarded
  /// through the [JsAppErrorFeedback] gate by the sink's owner. Null
  /// publishes into the app-wide [JsAppErrorChannel.instance] (the
  /// authoring session's delivery channel); the pre-flight smoke gate
  /// passes a local collector so gate probes never publish into the live
  /// session.
  final void Function(JsAppErrorEvent event)? errorSink;

  /// Content revision of the entry file the CURRENT run booted from — the
  /// dedup key boundary of the error gate (an edit re-arms reporting).
  String get sourceRevision => _sourceRevision ?? '';
  String? _sourceRevision;

  /// Whether this engine joins the process-wide per-app live-engine
  /// sibling group (gh-1164 review): live view engines (board tile +
  /// fullscreen) sync `jsr.storage` state across viewports through the
  /// group. Throwaway probes — the `open_app` smoke gate, which boots a
  /// SCRATCH env copy — must stay out: their storage writes would
  /// otherwise reach the app's real live engines (and live writes would
  /// replay into the probe). Live views leave the default `true`.
  final bool joinSiblingGroup;

  final void Function(String line)? _onLog;

  /// The latest rendered UI tree; the view listens and rebuilds.
  final ValueNotifier<Map<String, dynamic>?> tree =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// Set when the engine started but produced no UI tree within
  /// [uiTreeWarnAfter] — the eval died before the first render (issue
  /// #1336). The runtime swallows widget-eval failures: a syntax error
  /// aborts the whole script parse, so neither the wrapper's inner JS
  /// try/catch nor the host's can see it (the backend only debugPrints
  /// the eval error). The views render this as an error card instead of
  /// an infinite spinner. A plain display String — no error type, so no
  /// `Bad state:` prefix leaks into user-facing cards.
  final ValueNotifier<String?> bootError = ValueNotifier<String?>(null);

  /// How long after [start] a null [tree] turns into [bootError].
  @visibleForTesting
  static Duration uiTreeWarnAfter = const Duration(seconds: 10);

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

  /// Per-process group of LIVE engines keyed by app id — the sibling set
  /// `state.sync` storage broadcasts fan out to (see
  /// [_broadcastStorageChanges]). An engine joins on a successful [start]
  /// and leaves on [dispose]; the map only ever holds live engines.
  static final Map<String, Set<JsAppEngine>> _liveByApp = {};

  /// Distinguishes this instance's own storage echoes from sibling writes
  /// in the `state.sync` payload (widgets use it as the `writer` guard).
  static int _nextInstanceId = 0;

  /// Unique per engine instance (see [_nextInstanceId]).
  final String instanceId = 'e${++_nextInstanceId}';

  /// The storage snapshot the diff in [_persistStorage] is computed
  /// against — seeded from disk at boot so the app's FIRST write diffs
  /// against what previous instances left behind, not against empty.
  Map<String, dynamic>? _lastPersistedStorage;

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
  ///
  /// Probed via [BindingBase.debugBindingType] (null when no binding is
  /// initialized, e.g. plain `test()`s with no widget tree) — never via
  /// `WidgetsBinding.instance`, which THROWS in that state (gh-1266).
  static bool get _inWidgetTest {
    final type = BindingBase.debugBindingType();
    return type != null &&
        type.toString().contains('TestWidgetsFlutterBinding');
  }

  /// Serializes [action] process-wide in production; runs it directly
  /// under widget tests (see [_inWidgetTest]).
  static Future<T> _guardLifecycle<T>(Future<T> Function() action) =>
      _inWidgetTest ? action() : _lifecycle(action);

  Map<String, dynamic>? get exportedState => _engine?.exportedState;
  List<Map<String, dynamic>> peekLogs() => _engine?.peekLogs() ?? const [];

  /// The bridge-owned voxel world behind `voxel` nodes (`jsr.hostCall(
  /// 'voxel.*')`): the SAME world the running engine's backend created at
  /// start and every `voxel.attach`/`voxel.mesh`/`voxel.camera` call lands
  /// in (gh-1441). Surfaces pass it to [JsonWidgetRenderer.voxelWorld] —
  /// without it the renderer swaps every `voxel` node for the "Voxel
  /// world" placeholder while the engine side reports success.
  ///
  /// Null before [start] and after [dispose]/restart, so a re-render after
  /// a reload always wires the CURRENT world — never a stale one from a
  /// disposed engine.
  JsVoxelWorld? get voxelWorld => _engine?.voxelWorld;

  /// Whether the one-shot unwired-voxel diagnostic already fired (see
  /// [noteUnwiredVoxelWorld]).
  bool _unwiredVoxelNoted = false;

  /// gh-1441 AC3: when a tree carries a `voxel` node while this engine has
  /// NO voxel world, the renderer draws its "Voxel world" placeholder —
  /// indistinguishable from a broken widget unless the host says why. A
  /// minimal custom backend ships no world (`JsWidgetEngine.voxelWorld`
  /// returns null there); shipped backends always have one, so on them
  /// this never fires. Logs ONCE per engine boot.
  void noteUnwiredVoxelWorld(Map<String, dynamic> tree) {
    // Live engine only. `_start()` nulls `_engine` before the async
    // dispose/boot while `tree.value` still publishes the old tree — a
    // rebuild in that gap renders the placeholder transiently and must
    // NOT spend the one-shot (it would warn on shipped backends, and the
    // flag would stay spent for the rest of the instance). AC3's actual
    // subject is a LIVE engine whose backend ships no world (gh-1441
    // review).
    final engine = _engine;
    if (_unwiredVoxelNoted || engine == null || engine.voxelWorld != null) {
      return;
    }
    if (!_containsVoxelNode(tree, depth: 0)) return;
    _unwiredVoxelNoted = true;
    AppLog.i(
      'apps',
      'WARNING: ${app.id}/$entryFile: voxel node in the rendered tree but '
          'no voxelWorld is wired — the bridge world is missing on this '
          'engine (minimal backend?); the "Voxel world" placeholder is host '
          'wiring, not a broken widget',
    );
  }

  /// Whether [node] — a JSON widget tree — contains a `voxel` node
  /// anywhere (recursing through child maps/lists, depth-capped).
  ///
  /// Complexity is held ≤5 deliberately: the CI app-crap-gate measures
  /// this file against the ubuntu shard coverage, where the walk is
  /// unreachable in tests (it needs a LIVE engine whose backend ships no
  /// world — a state no host constructs), so an uncovered CC-9 first cut
  /// measured CRAP 90 > 30 and failed the ratchet (CI run 37974606427).
  /// The [containsVoxelNodeForTest] pins below keep it covered anyway;
  /// only-down from here.
  static bool _containsVoxelNode(Object? node, {required int depth}) {
    if (depth > 64) return false;
    if (node is Map) {
      return node['type'] == 'voxel' ||
          node.values.any(
            (value) => _containsVoxelNode(value, depth: depth + 1),
          );
    }
    if (node is List) {
      return node.any((value) => _containsVoxelNode(value, depth: depth + 1));
    }
    return false;
  }

  /// Direct unit seam for the JSON-tree walk behind
  /// [noteUnwiredVoxelWorld]: the walk is reachable in production only
  /// with a LIVE engine whose backend ships no voxel world — a state no
  /// host can construct (no backend injection seam on [JsAppEngine]) —
  /// so the recursion is pinned through here, bridge-independent (the
  /// [assembleEntryJsForTest] pattern, issue #184). The pins run on the
  /// bare ubuntu CI shards, where the engine-boot tests skip.
  @visibleForTesting
  static bool containsVoxelNodeForTest(Object? node) =>
      _containsVoxelNode(node, depth: 0);

  /// Starts (or restarts) the JS engine with the current [entryFile].
  Future<void> start() => _guardLifecycle(_start);

  Future<void> _start() async {
    final old = _engine;
    _engine = null;
    // A fresh boot re-arms the one-shot unwired-voxel diagnostic: start()
    // restarts the SAME instance, so a flag spent by an earlier boot would
    // silence a genuinely-unwired state after a reload (gh-1441 review).
    _unwiredVoxelNoted = false;
    if (old != null) await old.dispose();
    backHandlerRegistered.value = false;

    if (!app.supportsPlatform(currentFaPlatform)) {
      throw StateError("App '${app.id}' is not enabled on $currentFaPlatform");
    }

    // Log WHICH app boots — engine-start lines in the debug log used to
    // be indistinguishable between apps (and tiles vs full apps).
    AppLog.i('apps', 'engine start: ${app.id}/$entryFile');
    final js = await _assembleEntryJs();
    // gh-1164: the error gate dedups per source revision — hash the WHOLE
    // app source tree (entry + sibling source files), so an edit to any
    // app source file re-arms reporting (a helper-only fix used to leave
    // the old revision's silenced keys silenced, gh-1164 review).
    _sourceRevision = await computeSourceRevision(env, app.dir, entryFile);
    final storage = await _readStorage();
    final config = JsRuntimeConfig(
      widgetId: app.id,
      // The native router keys live engines by `instanceId ?? widgetId`:
      // without a unique id, the board tile and the fullscreen engine of
      // the same app collide on `widgetId` — last registration wins the
      // route and the FIRST dispose drops the shared route entry, leaving
      // the surviving engine's render/storage/timer messages dead
      // (frozen tile, buttons that silently do nothing).
      instanceId: instanceId,
      initialTheme: initialTheme,
      initialStorage: storage,
      hostBootstrapJs: faBootstrapJsFor(hostLocale),
      onRender: (t) {
        // A late render (slow device, bootstrap that fetches before its
        // first jsr.render) proves the boot was fine — clear the
        // watchdog's stale verdict so the widget surfaces instead of
        // hiding behind a permanent error card (gh-1336 review).
        bootError.value = null;
        tree.value = t;
      },
      onSetTitle: (_) {},
      onStorageUpdate: _persistStorage,
      onLog: _handleEngineLog,
      isPermissionAllowed: _isAllowed,
      onResolveReady: (resolve) => _resolve = resolve,
      fetchHandler: _fetch,
      loadAssetHandler: _loadAsset,
      execHandler: _exec,
      // The dispatcher singleton (cube for primitives/OBJ, flame_3d for
      // GLB/GLTF) — shared with the renderer's `js3dHost`, which resolves
      // the same per-sceneId controllers the bridge mutates.
      js3dHost: createFaJs3dHost(env),
      // External links leave the app: jsr.openUrl(url) opens the host
      // browser (rejects with {'__error': ...} when the URL cannot be
      // launched).
      openUrlHandler: _openUrl,
      // Embedded web content for `webView` nodes; null → the renderer's
      // placeholder on platforms without a webview plugin.
      webViewHost: webViewHost ?? createFaWebViewHost(),
    );
    final engine = JsWidgetEngine(config: config);
    _engine = engine;
    await engine.run(js);
    // Live now: join the app's sibling group so later storage writes from
    // OTHER engines of the same app reach this one (and vice versa).
    // Smoke-gate probes (joinSiblingGroup: false) stay out — they boot on
    // a scratch env and must never see or send live storage state.
    if (joinSiblingGroup) {
      _liveByApp.putIfAbsent(app.id, () => <JsAppEngine>{}).add(this);
    }
    // Boot-race healing: a sibling write landing between the storage read
    // above and this point was persisted but never delivered (we were not
    // in the group yet / the JS engine was not ready). Re-read the file and
    // replay the drift into THIS engine as `state.sync` events — the widget
    // adopts them through the same path as live broadcasts.
    await _replayStorageDrift();
    // Issue #1336: a healthy widget renders within a frame or two; a
    // broken one (source fails to parse/eval) never renders at all —
    // arm the null-tree watchdog so the failure surfaces as an error
    // card instead of an infinite spinner.
    unawaited(_watchUiTree(_engine));
  }

  /// Issue #1336: logs a first-class warning and sets [bootError] when
  /// the widget eval produced no UI tree within [uiTreeWarnAfter] of
  /// start. [armed] pins the verdict to THIS run — a restart or dispose
  /// cancels it.
  Future<void> _watchUiTree(JsWidgetEngine? armed) async {
    await Future<void>.delayed(uiTreeWarnAfter);
    // A disposed engine's notifiers throw on read — check liveness first.
    if (!identical(_engine, armed)) return;
    if (tree.value != null) return;
    final waited = uiTreeWarnAfter.inSeconds >= 1
        ? '${uiTreeWarnAfter.inSeconds}s'
        : '${uiTreeWarnAfter.inMilliseconds}ms';
    bootError.value =
        "widget '${app.id}' ($entryFile) produced no UI tree within $waited "
        'of engine start — the app source likely fails to parse (syntax '
        'error); fix the widget source and retry';
    AppLog.i(
      'apps',
      'WARNING: ${app.id}/$entryFile: uiTree not set $waited after '
          'engine start — eval failed before the first render',
    );
  }

  Future<void> callEvent(String actionId, [Map<String, dynamic>? payload]) {
    final engine = _engine;
    if (engine == null) return Future.value();
    return engine.callEvent(actionId, payload);
  }

  /// Reads and assembles the entry JS for [start] through the runtime's
  /// own [WidgetManifest] assembler: relative `import './x.js'` statements
  /// and `jsr.include('…')` calls are inlined (depth-capped, each file
  /// once, `export` stripped) and a manifest `files` list defines the load
  /// order. The install side (`catalog_service.dart`) unpacks whole
  /// multi-file apps — booting the raw entry text made any app whose
  /// entry is a bare `import './game/main.js';` die as a script syntax
  /// error: no `jsr.render`, the view stuck on its spinner (gh-1207).
  ///
  /// The manifest namespace always names the entry `widget.js`
  /// ([WidgetManifest.mainJsPath]) while [entryFile] may name a live-tile
  /// entry, so the reader redirects that one path (see
  /// [_AppWidgetFileReader]). The entry file itself stays the contract:
  /// a missing one fails the start with a clear [StateError] (the view
  /// renders its error card instead of spinning forever).
  Future<String> _assembleEntryJs() =>
      assembleEntryJsForTest(env: env, dir: app.dir, entryFile: entryFile);

  /// Test seam over the entry assembly [start] runs: host-side only —
  /// env reads plus the manifest assembler, no [JsWidgetEngine] — so the
  /// gh-1207 boot contract (bare-import entries assemble, missing entries
  /// fail with a clear [StateError]) is directly unit-testable on hosts
  /// without the native JS bridge (issue #184; the engine-boot tests stay
  /// bridge-gated).
  @visibleForTesting
  static Future<String> assembleEntryJsForTest({
    required ExecutionEnv env,
    required String dir,
    required String entryFile,
  }) async {
    final reader = _AppWidgetFileReader(env, dir: dir, entryFile: entryFile);
    final manifest = await WidgetManifest.fromStorage(dir, reader: reader);
    if (manifest == null) {
      throw StateError('app entry not found: $dir/$entryFile');
    }
    // A manifest `files` list makes readJs concatenate the full-app bundle
    // and never read the (redirected) entry path — for a live-tile entry
    // that would render the whole app inside the tile. Upstream
    // WidgetManifest has no copyWith, so rebuild it with `files: null`
    // when booting a non-default entry (gh-1207 review).
    final effective = entryFile == defaultEntryFile
        ? manifest
        : WidgetManifest(
            id: manifest.id,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            icon: manifest.icon,
            allowedCommands: manifest.allowedCommands,
            networkEnabled: manifest.networkEnabled,
            widgetPath: manifest.widgetPath,
            isSingleFile: manifest.isSingleFile,
            cli: manifest.cli,
          );
    final js = await effective.readJs(reader: reader);
    if (js == null) {
      throw StateError('app entry not found: $dir/$entryFile');
    }
    return js;
  }

  /// Test seam over the [WidgetFileReader] the entry assembler runs over
  /// [env]: the manifest-namespace reader ([_AppWidgetFileReader]) with
  /// its entry-path redirect — host-only, no JS engine needed.
  @visibleForTesting
  static WidgetFileReader appWidgetFileReaderForTest({
    required ExecutionEnv env,
    required String dir,
    required String entryFile,
  }) => _AppWidgetFileReader(env, dir: dir, entryFile: entryFile);

  /// Content revision of the app's whole source tree — the entry file
  /// plus every sibling source file under [dir], hashed in sorted path
  /// order (gh-1164 review): the error gate's dedup boundary keys on
  /// this, so an edit to ANY app source file (including helper modules
  /// the entry only reaches transitively) re-arms reporting. Runtime
  /// state (`storage.json`, `session.json`) is NOT source and stays out
  /// of the hash.
  @visibleForTesting
  static Future<String> computeSourceRevision(
    ExecutionEnv env,
    String dir,
    String entryFile,
  ) async {
    final files = <(String, String)>[];
    Future<void> walk(String path) async {
      final entries = (await env.listDir(path)).valueOrNull;
      if (entries == null) return;
      for (final entry in entries) {
        if (entry.kind == FileKind.directory) {
          await walk(entry.path);
          continue;
        }
        if (entry.name == 'storage.json' || entry.name == 'session.json') {
          continue; // runtime state, not source
        }
        final text = (await env.readTextFile(entry.path)).valueOrNull;
        if (text == null) continue; // binary asset — not app source
        files.add((entry.path, text));
      }
    }

    await walk(dir);
    files.sort((a, b) => a.$1.compareTo(b.$1));
    final buffer = StringBuffer('$dir/$entryFile\n');
    for (final (path, text) in files) {
      buffer.write('$path\n$text\n');
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
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
    final siblings = _liveByApp[app.id];
    if (siblings != null) {
      siblings.remove(this);
      if (siblings.isEmpty) _liveByApp.remove(app.id);
    }
    if (engine != null) await engine.dispose();
    tree.dispose();
    bootError.dispose();
    backHandlerRegistered.dispose();
  });

  // --- error capture (gh-1164 Part B) ----------------------------------------

  /// The `__jsr_log` tap: plain lines pass to the host's log sink
  /// unchanged; the bootstrap's structured `faAppError:` records (gh-1164)
  /// are ALSO forwarded to the error sink (the channel's gate decides
  /// delivery).
  void _handleEngineLog(String line) {
    final event = parseJsAppErrorLogLine(line);
    if (event != null) _forwardError(event);
    _onLog?.call(line);
  }

  /// Forwards one captured error to this engine's sink. The surface is the
  /// live viewport: the full app (default entry) or the launcher tile.
  /// With no local sink the app-wide channel gates first — only a
  /// first-per-revision occurrence is published for delivery (AC4/AC6
  /// anti-spam).
  void _forwardError(JsAppErrorEvent event) {
    if (errorSink != null) {
      errorSink!(event);
      return;
    }
    final feedback = JsAppErrorChannel.instance.reportAppError(
      event,
      appId: app.id,
      surface: entryFile == JsAppEngine.defaultEntryFile ? 'app' : 'tile',
      sourceRevision: sourceRevision,
    );
    if (feedback == null || !feedback.deliver) return; // dedup / breaker
    JsAppErrorChannel.instance.publish(
      JsAppErrorNotice(
        event: event,
        appId: app.id,
        surface: entryFile == JsAppEngine.defaultEntryFile ? 'app' : 'tile',
        sourceRevision: sourceRevision,
        notice: feedback.notice,
      ),
    );
  }

  /// Host-side error capture (gh-1164): Flutter render-host exceptions and
  /// any other surface failure the view wants on the agent's channel —
  /// same gate + delivery as JS-reported errors.
  void reportHostError(
    String message, {
    String kind = 'render',
    String? stack,
  }) {
    final parsed = JsAppErrorKind.values.asNameMap()[kind];
    _forwardError(
      JsAppErrorEvent(
        kind: parsed ?? JsAppErrorKind.render,
        message: message,
        stack: stack ?? '',
      ),
    );
  }

  // --- storage persistence + live sync ---------------------------------------

  String get _storagePath => '${app.dir}/storage.json';

  Future<Map<String, dynamic>> _readStorage() async {
    final decoded = await _readStorageFile();
    // Seed the diff baseline: the first write of THIS instance must
    // broadcast only what it actually changed relative to what a sibling
    // (or a previous run) already persisted.
    _lastPersistedStorage = decoded;
    return decoded;
  }

  /// Reads `storage.json` without touching the diff baseline; empty on a
  /// missing or corrupt file (same fresh-start rule as boot).
  Future<Map<String, dynamic>> _readStorageFile() async {
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
    return const {};
  }

  void _persistStorage(Map<String, dynamic> storage) {
    unawaited(env.writeFile(_storagePath, jsonEncode(storage)));
    _broadcastStorageChanges(_lastPersistedStorage ?? const {}, storage);
    _lastPersistedStorage = Map<String, dynamic>.of(storage);
  }

  /// Reserved event name carrying storage diffs between live engines of
  /// one app (see the class doc). Widgets treat it as protocol, never as a
  /// UI action.
  static const String stateSyncEvent = 'state.sync';

  /// Fans the changed `jsr.storage` keys out to the app's OTHER live
  /// engines as `state.sync` events (`{appId, key, value, writer}`), so a
  /// board tile and the fullscreen view (or two tiles) stay one logical
  /// instance. Fire-and-forget: siblings that never started or just
  /// disposed no-op inside [callEvent]. Adoption on the receiving side
  /// must NOT write back — the `rev`/`writer` guard in the state protocol
  /// keeps equal-rev echoes inert, so no broadcast loop is possible.
  void _broadcastStorageChanges(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    _broadcastStorageTo(_liveByApp[app.id], before, after);
  }

  /// The broadcast core: diff [before] → [after], deliver to every
  /// non-self engine in [siblings] (issue #560 descent: diff computation
  /// split from the fan-out, both small and unit-testable).
  void _broadcastStorageTo(
    Iterable<JsAppEngine>? siblings,
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    if (siblings == null || siblings.length < 2) return;
    _deliverStorageChanges(siblings, storageDiff(before, after));
  }

  void _deliverStorageChanges(
    Iterable<JsAppEngine> siblings,
    Map<String, dynamic> changed,
  ) {
    if (changed.isEmpty) return;
    for (final sibling in siblings) {
      if (!identical(sibling, this)) {
        _sendStateSync(sibling, changed, writer: instanceId);
      }
    }
  }

  /// One fan-out leg: [changed] becomes one `state.sync` event per entry
  /// on [target] (see [stateSyncEvent] for the protocol shape).
  void _sendStateSync(
    JsAppEngine target,
    Map<String, dynamic> changed, {
    required String writer,
  }) {
    for (final entry in changed.entries) {
      unawaited(
        target.callEvent(stateSyncEvent, {
          'appId': app.id,
          'key': entry.key,
          'value': entry.value,
          'writer': writer,
        }),
      );
    }
  }

  /// Keys whose value differs between [before] and [after], mapped to the
  /// NEW value; keys removed in [after] map to null. Values compare by
  /// JSON encoding, so a mutated nested map counts as changed and a fresh
  /// deep-equal instance does not (issue #560 descent: the pure core of
  /// the storage sync, shared by the live broadcast and the boot replay).
  @visibleForTesting
  static Map<String, dynamic> storageDiff(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    final changed = _changedStorageValues(before, after);
    for (final key in before.keys) {
      if (!after.containsKey(key)) changed[key] = null;
    }
    return changed;
  }

  static Map<String, dynamic> _changedStorageValues(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    final changed = <String, dynamic>{};
    for (final key in after.keys) {
      if (!_sameStorageValue(before[key], after[key])) {
        changed[key] = after[key];
      }
    }
    return changed;
  }

  static bool _sameStorageValue(Object? a, Object? b) =>
      identical(a, b) || jsonEncode(a) == jsonEncode(b);

  /// Delivers this engine the storage changes OTHERS persisted while this
  /// instance was still booting (see [_start]). `writer: 'boot'` marks the
  /// replay so widgets can tell it from a live sibling write; delivery
  /// goes through the same reserved `state.sync` event. Fire-and-forget —
  /// a failure here must never fail the start.
  Future<void> _replayStorageDrift() async {
    try {
      final baseline = _lastPersistedStorage ?? const {};
      final latest = await _readStorageFile();
      final changed = storageDiff(baseline, latest);
      if (changed.isEmpty) return;
      _lastPersistedStorage = Map<String, dynamic>.of(latest);
      _sendStateSync(this, changed, writer: 'boot');
    } on Object {
      // Best-effort: the next live broadcast (or a restart) re-syncs.
    }
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

  // --- jsr.openUrl -----------------------------------------------------------

  /// `jsr.openUrl(url)` → `true` opened in the host's external browser; an
  /// unparseable URL or one the platform cannot launch (and a failed
  /// launch) reject the JS promise with `{'__error': ...}`.
  Future<void> _openUrl(String id, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !await canLaunchUrl(uri)) {
      _resolve?.call(id, {'__error': 'cannot launch $url'});
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    _resolve?.call(id, ok ? true : {'__error': 'launch failed'});
  }

  // --- jsr.exec + the jsr.fa bridge ------------------------------------------

  /// The fa bootstrap with the host locale baked in: `jsr.locale` is set
  /// before any app code runs (theme pushes only cover `jsr.theme`). Public
  /// so the bridge-parity test can assert the exact method set every engine —
  /// installed apps AND dynamic-message widgets — boots with (AC6).
  static String faBootstrapJsFor(String locale) {
    final safe = locale.replaceAll("'", '');
    return "jsr.locale = '$safe';\n$_faBootstrapJs";
  }

  // Raw string (gh-1266 / gh-1272): the gh-1164 fingerprint block below
  // embeds JS regex char classes (/[ \t\r\n]+/) and '\n' string literals —
  // a non-raw Dart literal unescapes those into REAL tab/CR/LF before the
  // JS engine ever sees the source, so the JS parser rejects the regex
  // literal ("unexpected line terminator in regexp"), killing the whole
  // widget eval (bootstrap + app code in one script) on every
  // engine-capable host (macOS JSC, Linux/Windows QuickJS). No $
  // interpolation inside; raw is safe.
  static const String _faBootstrapJs = r'''
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

// Theme packs (issue #169): declarative-only theme access, gated on the
// `theme` manifest flag. list() → {packs: [{id, name, version,
// hasWallpaper, contrastWarnings}]}; current() → {pack: {...} | null};
// apply(id) ALWAYS prompts the user — a declined prompt resolves
// {applied: false, reason: 'denied'}, an unknown id rejects. There is
// deliberately no install/uninstall: packs enter Fa only through the
// user's own file import, never through app code.
jsr.fa.theme = {
  list: function() { return jsr.fa.call('theme.list', {}); },
  current: function() { return jsr.fa.call('theme.current', {}); },
  apply: function(id) { return jsr.fa.call('theme.apply', {id: id}); },
};

// Widget->host event channel (dynamic messages): fire-and-forget emit of one
// named event with a JSON payload; the host forwards it to the agent as a
// user message. Resolves {emitted: true|false} — false when the host has no
// sink (installed apps).
jsr.fa.emit = function(event, payload) { return jsr.fa.call('emit', {event: event, payload: payload || {}}); };

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

// gh-1164 error reporting: load/runtime exceptions reach the AUTHORING
// AGENT, not only the screen. Every captured error rides one structured
// console.error record — the host's log channel already classifies it
// ('[E] ') and the engine parses the JSON payload into the session's
// error gate (dedup + delivery). Never remove or reword the marker.
(function() {
  // Stable fingerprint for the dedup gate (gh-1164 review): normalize
  // per-occurrence noise (numbers, hex ids, whitespace) out of the
  // message and keep only the first app frame's location shape, so
  // "Failed to load chunk 14" vs "chunk 15" or per-frame layout values
  // collapse to ONE key — the circuit breaker can actually trip on the
  // noisy failure class (RAF/animation loops) instead of seeing a new
  // key every occurrence.
  var __faFingerprint = function(message, stack) {
    try {
      var norm = String(message)
        .replace(/0x[0-9a-fA-F]+/g, '#')
        .replace(/[0-9]+/g, '#')
        .replace(/[ \t\r\n]+/g, ' ')
        .trim();
      var frame = '';
      var lines = String(stack || '').split('\n');
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line && line.indexOf('__faReport') < 0 &&
            line.indexOf('__wrapCb') < 0 &&
            line.indexOf('__faFingerprint') < 0) {
          frame = line;
          break;
        }
      }
      frame = frame.replace(/:[0-9]+:[0-9]+/g, '').replace(/[ \t\r\n]+/g, ' ').trim();
      return norm + '\n' + frame;
    } catch (e) {
      return '';
    }
  };
  var __faReport = function(kind, message, stack) {
    try {
      console.error('faAppError:' + JSON.stringify({
        kind: kind,
        message: String(message),
        stack: String(stack || ''),
        fingerprint: __faFingerprint(message, stack)
      }));
    } catch (e) {}
  };
  // 1. jsr.showError is the runtime's own crash surface (the widget eval
  //    wrapper reports every load-time throw through it) — report in
  //    addition to rendering the overlay.
  var baseShowError = jsr.showError;
  jsr.showError = function(msg) {
    var stack = '';
    try { stack = (new Error('')).stack || ''; } catch (e) {}
    __faReport('showError', msg, stack);
    return baseShowError(msg);
  };
  // 2. Timer + RAF callbacks: exceptions there are swallowed by the
  //    bridge (an animation frame throwing 100x would die silently) —
  //    wrap, report, and keep the previous swallow semantics.
  var __wrapCb = function(fn) {
    if (typeof fn !== 'function') return fn;
    return function() {
      try { return fn.apply(this, arguments); }
      catch (e) {
        __faReport('callback', (e && e.message) ? e.message : String(e), (e && e.stack) || '');
      }
    };
  };
  var baseSetTimeout = setTimeout;
  setTimeout = function(fn, ms) { return baseSetTimeout(__wrapCb(fn), ms); };
  var baseSetInterval = setInterval;
  setInterval = function(fn, ms) { return baseSetInterval(__wrapCb(fn), ms); };
  var baseRaf = requestAnimationFrame;
  requestAnimationFrame = function(fn) { return baseRaf(__wrapCb(fn)); };
  // 3. window.onerror + unhandledrejection cover everything else.
  if (typeof window !== 'undefined') {
    window.onerror = function(message, source, lineno, colno, error) {
      __faReport('onerror', message, (error && error.stack) || '');
    };
    window.onunhandledrejection = function(event) {
      var reason = event && event.reason;
      __faReport('unhandledrejection',
        (reason && reason.message) ? reason.message : String(reason),
        (reason && reason.stack) || '');
    };
  }
})();
''';

  Future<void> _exec(String id, String cmd) async {
    final envelope = parseFaEnvelope(cmd);
    if (envelope != null) {
      await _faCall(id, envelope.fa, envelope.args);
      return;
    }
    await _execShell(id, cmd);
  }

  /// The `jsr.fa` bridge envelope riding on exec (issue #565 descent):
  /// `{"fa": "<method>", "args": {...}}` — null for a plain shell command,
  /// malformed JSON, or JSON without a string `fa` field.
  @visibleForTesting
  static ({String fa, Map<String, Object?> args})? parseFaEnvelope(String cmd) {
    if (!cmd.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(cmd);
      if (decoded is Map<String, dynamic> && decoded['fa'] is String) {
        return (
          fa: decoded['fa'] as String,
          args: (decoded['args'] as Map?)?.cast<String, Object?>() ?? const {},
        );
      }
    } on FormatException {
      // Not a bridge call — fall through to shell handling.
    }
    return null;
  }

  /// The shell leg of [_exec]: the allow-listed command runs in the env and
  /// resolves as {stdout, stderr, exitCode}; anything else is a denial or
  /// the env's own error.
  Future<void> _execShell(String id, String cmd) async {
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

  /// `jsr.fa.*` bridge dispatch (issue #433 descent). The old if-chain was
  /// CC 49 / CRAP 2450 — the repo's worst offender. Methods route through
  /// one map; the `llm` trio, host channels (`back.*`, `emit`) and the
  /// platform-prefix fallback keep their exact previous semantics,
  /// including the permission-denied error an unknown prefix produces.
  late final Map<String, Future<Object?> Function(Map<String, Object?> args)>
  _faHandlers = {
    'llm': (args) => _faLlm('llm', args),
    'llm.chat': (args) => _faLlm('llm.chat', args),
    'llm.stream': (args) => _faLlm('llm.stream', args),
    'calendar.events': _calendarEvents,
    'calendar.create': _calendarCreate,
    'calendar.update': _calendarUpdate,
    'calendar.delete': _calendarDelete,
    'contacts.search': _contactsSearch,
    'contacts.create': _contactsCreate,
    'contacts.update': _contactsUpdate,
    'contacts.delete': _contactsDelete,
    'contacts.call': _contactsCall,
    'contacts.sms': _contactsSms,
    'health.summary': _healthSummary,
    'asr.record': _asrRecord,
    'asr.stop': (args) async {
      final signal = _asrStopSignal;
      if (signal != null && !signal.isCompleted) signal.complete();
      return {'stopped': signal != null};
    },
    'asr.transcribe': _asrTranscribe,
    'notify.schedule': _notifySchedule,
    'notify.cancel': _notifyCancel,
    'media.generateImage': _mediaGenerateImage,
    'media.speak': _mediaSpeak,
    'media.generateMusic': _mediaGenerateMusic,
    'media.generateVideo': _mediaGenerateVideo,
    'media.readVideo': _mediaReadVideo,
    'keys.list': (args) async => _keysList(),
    'keys.get': (args) async => _keysGet(args),
    'keys.request': _keysRequest,
    'theme.list': (args) => _themeList(),
    'theme.current': (args) => _themeCurrent(),
    'theme.apply': _themeApply,
    // Home control (iOS HomeKit). `home.*` is the current surface; the
    // legacy `homekit.<action>` calls route to the same handlers.
    'home.homes': (args) => _homeCall('homes', args),
    'home.rooms': (args) => _homeCall('rooms', args),
    'home.list': (args) => _homeCall('list', args),
    'home.read': (args) => _homeCall('read', args),
    'home.write': (args) => _homeCall('write', args),
    'home.scenes': (args) => _homeCall('scenes', args),
    'home.executeScene': (args) => _homeCall('executeScene', args),
    'home.setPower': (args) => _homeCall('setPower', args),
    'home.setBrightness': (args) => _homeCall('setBrightness', args),
    'home.setTemperature': (args) => _homeCall('setTemperature', args),
    'homekit.homes': (args) => _homeCall('homes', args),
    'homekit.rooms': (args) => _homeCall('rooms', args),
    'homekit.list': (args) => _homeCall('list', args),
    'homekit.listDevices': (args) => _homeCall('list', args),
    'homekit.read': (args) => _homeCall('read', args),
    'homekit.write': (args) => _homeCall('write', args),
    'homekit.scenes': (args) => _homeCall('scenes', args),
    'homekit.executeScene': (args) => _homeCall('executeScene', args),
    'homekit.setPower': (args) => _homeCall('setPower', args),
    'homekit.setBrightness': (args) => _homeCall('setBrightness', args),
    'homekit.setTemperature': (args) => _homeCall('setTemperature', args),
    // Back-navigation contract (see _faBootstrapJs): the app reports its
    // jsr.onBack registration, and asks the host to close when a back
    // event went unconsumed. Neither is permission-gated.
    'back.handler': (args) async {
      backHandlerRegistered.value = args['registered'] == true;
      return true;
    },
    'back.close': (args) async {
      onCloseRequested?.call();
      return true;
    },
    // Widget->host event channel (dynamic messages): fire-and-forget emit
    // of one named event with a JSON payload. NOT permission-gated — the
    // host sink is injected by the presenter (see [onEmit]); installed
    // apps have none and the bridge resolves {emitted: false}.
    'emit': _faEmit,
  };

  Future<void> _faCall(
    String id,
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      final handler =
          _faHandlers[method] ?? (args) => _faPlatform(method, args);
      _resolve?.call(id, await handler(args));
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  /// The `jsr.fa.llm` / `llm.chat` / `llm.stream` bridge: resolves with the
  /// assistant reply (accumulated text for streams). Permission-gated on
  /// `llm`; a missing handler is a setup error, not a permission error.
  Future<Object?> _faLlm(String method, Map<String, Object?> args) async {
    if (!permissions.llm) throw StateError(_denied('llm'));
    final handler = llmHandler;
    if (handler == null) {
      throw StateError(
        'no LLM is connected — connect a model in the Fa settings first',
      );
    }
    final messages = _faLlmMessages(method, args);
    if (method != 'llm.stream') return handler(messages);
    return _faLlmStream(handler, messages, (args['stream'] ?? '').toString());
  }

  /// A bare `llm` call carries `{prompt}`; the chat/stream forms carry
  /// `{messages}`.
  List<FaLlmMessage> _faLlmMessages(String method, Map<String, Object?> args) {
    if (method == 'llm') {
      return [(role: 'user', content: (args['prompt'] ?? '').toString())];
    }
    return parseLlmMessages(args['messages']);
  }

  Future<Object?> _faLlmStream(
    FaLlmHandler handler,
    List<FaLlmMessage> messages,
    String streamId,
  ) {
    // Deltas cross back as reserved 'llm.delta' events (see
    // _faBootstrapJs) carrying the accumulated partial text.
    final partial = StringBuffer();
    return handler(
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
    );
  }

  Future<Map<String, Object?>> _faEmit(Map<String, Object?> args) async {
    final event = (args['event'] ?? '').toString();
    if (event.isEmpty) return {'__error': 'emit requires an event name'};
    final sink = onEmit;
    if (sink != null) {
      // A throwing host sink must not reject the bridge promise.
      try {
        sink(event, emitPayload(args['payload']));
      } on Object catch (error) {
        AppLog.i('apps', 'jsr.fa.emit handler failed: $error');
      }
    }
    return {'emitted': sink != null};
  }

  /// The `emit` payload (issue #565 descent): a map is copied so the JS
  /// object never aliases host state; anything else becomes an empty map.
  @visibleForTesting
  static Map<String, Object?> emitPayload(Object? payload) =>
      payload is Map ? Map<String, Object?>.from(payload) : const {};

  /// Platform-bridge fallback for `homekit.*` / `health.*` / `contacts.*`
  /// methods the map does not implement — permission-gated by prefix. A
  /// method with any other prefix (or an ungranted one) fails with the
  /// same permission-denied error the old chain produced.
  Future<Object?> _faPlatform(String method, Map<String, Object?> args) async {
    final prefix = method.split('.').first;
    if (!_faPrefixGranted(prefix)) throw StateError(_denied(prefix));
    final handler = platformHandler;
    if (handler == null) {
      throw StateError('$prefix bridge is not available on this platform yet');
    }
    return handler(method, args);
  }

  bool _faPrefixGranted(String prefix) {
    return switch (prefix) {
      'homekit' => permissions.homekit,
      'health' => permissions.health,
      'contacts' => permissions.contacts,
      _ => false,
    };
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
    final slot = calendarUpdateSlot(args);
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

  /// The `startHour`/`endHour`/`allDay` slot override of `calendar.update`
  /// (issue #565 descent) — null when the args touch none of the three keys
  /// (a metadata-only update must not move the event in time).
  @visibleForTesting
  static ({DateTime start, DateTime end, bool allDay})? calendarUpdateSlot(
    Map<String, Object?> args,
  ) {
    final hasSlot =
        args.containsKey('startHour') ||
        args.containsKey('endHour') ||
        args.containsKey('allDay');
    if (!hasSlot) return null;
    return calendarSlot(
      date: args['date']?.toString(),
      startHour: args['startHour'] as num?,
      endHour: args['endHour'] as num?,
      allDay: args['allDay'] == true,
    );
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
      phones: stringListArg(args, 'phones'),
      emails: stringListArg(args, 'emails'),
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
      phones: stringListArg(args, 'phones'),
      emails: stringListArg(args, 'emails'),
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
    final phone = await contactsPhone(api, args);
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
    final phone = await contactsPhone(api, args);
    final url = 'sms:$phone?&body=${Uri.encodeComponent(text)}';
    if (!await api.openUrl(url)) {
      throw StateError('could not open the Messages app for $phone');
    }
    return {'texting': phone};
  }

  /// The target phone for contacts.call/sms: the explicit `phone` arg, or
  /// the first number of the contact with `id` (issue #565 descent: static
  /// for the direct unit tests, the engine state never enters the lookup).
  @visibleForTesting
  static Future<String> contactsPhone(
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
  /// comma-separated string. Null when absent/empty (issue #560 descent:
  /// public for the direct unit tests, production callers are in-library).
  @visibleForTesting
  static List<String>? stringListArg(Map<String, Object?> args, String key) {
    final raw = args[key];
    if (raw == null) return null;
    final items = _stringList(raw is List ? raw : raw.toString().split(','));
    return items.isEmpty ? null : items;
  }

  /// The trimmed non-empty strings of [items].
  static List<String> _stringList(Iterable<Object?> items) {
    final out = <String>[];
    for (final item in items) {
      final text = item.toString().trim();
      if (text.isNotEmpty) out.add(text);
    }
    return out;
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
      final handler = _homeActions[action];
      if (handler == null) throw StateError('unknown home action "$action"');
      return await handler(api, args);
    } on Object catch (error) {
      AppLog.i('home', 'bridge $action failed: $error');
      rethrow;
    }
  }

  /// Test seam over [_homeCall]: the host-side dispatcher runs against an
  /// injected [HomeApi] without a live JS engine, so every per-action
  /// handler stays covered on runners where the live-engine suite is
  /// skip-guarded (see the engine test's `_engineSkip`).
  @visibleForTesting
  Future<Map<String, Object?>> homeCallForTest(
    String action,
    Map<String, Object?> args,
  ) => _homeCall(action, args);

  /// The `home.<action>` route table (issue #560 descent): each action is
  /// one small handler below; the map keeps [_homeCall] a pure dispatcher,
  /// mirroring the [_faHandlers] pattern. `homekit.*` aliases route here
  /// through the same table.
  late final Map<String, _HomeAction> _homeActions = {
    'homes': _homeHomes,
    'rooms': _homeRooms,
    'list': _homeList,
    'read': _homeRead,
    'write': _homeWrite,
    'scenes': _homeScenes,
    'executeScene': _homeExecuteScene,
    'setPower': _homeSetPower,
    'setBrightness': _homeSetBrightness,
    'setTemperature': _homeSetTemperature,
  };

  Future<Map<String, Object?>> _homeHomes(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
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
  }

  Future<Map<String, Object?>> _homeRooms(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    final rooms = await api.listRooms(homeId: _optionalString(args, 'homeId'));
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
  }

  Future<Map<String, Object?>> _homeList(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
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
  }

  Future<Map<String, Object?>> _homeRead(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    return {
      'accessory': _homeAccessoryMap(
        await api.readAccessory(id: _requiredId(args)),
      ),
    };
  }

  Future<Map<String, Object?>> _homeWrite(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
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
  }

  Future<Map<String, Object?>> _homeScenes(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
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
  }

  Future<Map<String, Object?>> _homeExecuteScene(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    await api.executeScene(id: _requiredId(args));
    return {'executed': true};
  }

  Future<Map<String, Object?>> _homeSetPower(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final on = args['on'] == true;
    await api.setPower(
      id: id,
      on: on,
      name: _optionalString(args, 'name'),
      room: _optionalString(args, 'room'),
    );
    return {'on': on};
  }

  Future<Map<String, Object?>> _homeSetBrightness(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final value = homeBrightness(args['value'] as num?);
    await api.setBrightness(
      id: id,
      value: value,
      name: _optionalString(args, 'name'),
      room: _optionalString(args, 'room'),
    );
    return {'brightness': value};
  }

  Future<Map<String, Object?>> _homeSetTemperature(
    HomeApi api,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final celsius = homeTemperature(args['celsius'] as num?);
    await api.setTargetTemperature(
      id: id,
      celsius: celsius,
      name: _optionalString(args, 'name'),
      room: _optionalString(args, 'room'),
    );
    return {'temperature': celsius};
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
    final path = mediaReadVideoPath(args);
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

  /// The sandbox path of `media.readVideo` (issue #565 descent) — required,
  /// trimmed; the app-visible path the env maps to a host one.
  @visibleForTesting
  static String mediaReadVideoPath(Map<String, Object?> args) {
    final path = (args['path'] ?? '').toString().trim();
    if (path.isEmpty) throw StateError('path is required');
    return path;
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
    final request = keysRequestArgs(args, appName: app.name);
    final result = await handler(request.name, request.reason);
    if (result == null) {
      throw StateError('the user declined to provide ${request.name}');
    }
    return {'name': result.name, 'value': result.value};
  }

  /// The validated name + prompt reason of `keys.request` (issue #565
  /// descent): the name is required; an absent/blank reason defaults to a
  /// sentence naming the asking app and the key.
  @visibleForTesting
  static ({String name, String reason}) keysRequestArgs(
    Map<String, Object?> args, {
    required String appName,
  }) {
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) throw StateError('name is required');
    final custom = (args['reason'] ?? '').toString().trim();
    final reason = custom.isEmpty
        ? 'The app "$appName" asks for the $name key.'
        : custom;
    return (name: name, reason: reason);
  }

  /// The permission gate every `jsr.fa.theme.*` call shares: the `theme`
  /// manifest flag plus a session theme bridge (the host injects one only
  /// where it can render the consent prompt).
  FaThemeBridge _gatedTheme() {
    if (!permissions.theme) throw StateError(_denied('theme'));
    final bridge = themeBridge;
    if (bridge == null) {
      throw StateError(
        'theme packs are not available in this session — open a session '
        'screen that supports them',
      );
    }
    return bridge;
  }

  /// `jsr.fa.theme.list()` → `{packs: [...]}` — the installed packs as
  /// declarative descriptors (id, name, version, hasWallpaper,
  /// contrastWarnings). No colors cross the wire here; an app that wants
  /// the active palette reads `jsr.theme` (pushed by the host).
  Future<Map<String, Object?>> _themeList() async => {
    'packs': await _gatedTheme().listPacks(),
  };

  /// `jsr.fa.theme.current()` → `{pack: {...} | null}` — the active pack's
  /// descriptor, null for the stock Fa look.
  Future<Map<String, Object?>> _themeCurrent() async => {
    'pack': await _gatedTheme().currentPack(),
  };

  /// `jsr.fa.theme.apply({id})` → `{applied: true|false, reason?}` — asks
  /// the user; the host ALWAYS prompts (issue #169 security model). A
  /// declined prompt resolves `{applied: false, reason: 'denied'}` (a
  /// normal outcome, not an error); an unknown id rejects.
  Future<Map<String, Object?>> _themeApply(Map<String, Object?> args) async {
    final id = (args['id'] ?? '').toString().trim();
    if (id.isEmpty) throw StateError('id is required');
    return _gatedTheme().applyPack(id);
  }

  /// Validates the `messages` argument of `llm.chat`/`llm.stream`:
  /// `[{role: 'user'|'assistant'|'system', content: '...'}]`.
  @visibleForTesting
  static List<FaLlmMessage> parseLlmMessages(Object? raw) {
    if (raw is! List) {
      throw StateError('messages must be a list of {role, content} objects');
    }
    final messages = [for (final entry in raw) _parseLlmMessage(entry)];
    if (messages.isEmpty) throw StateError('messages must not be empty');
    return messages;
  }

  /// One validated message: the role must be one of the three supported
  /// ones; content coerces to a string (null → '').
  static FaLlmMessage _parseLlmMessage(Object? entry) {
    if (entry is! Map) {
      throw StateError('each message must be a {role, content} object');
    }
    final role = (entry['role'] ?? '').toString();
    const roles = {'user', 'assistant', 'system'};
    if (!roles.contains(role)) {
      throw StateError(
        'unsupported message role "$role" (user/assistant/system)',
      );
    }
    return (role: role, content: (entry['content'] ?? '').toString());
  }

  String _denied(String what) =>
      '$what permission is disabled for "${app.name}" '
      '(enable it in the app permissions)';
}

/// [WidgetFileReader] over the app's [ExecutionEnv] behind
/// [JsAppEngine._assembleEntryJs]: every assembler path is env-relative
/// under the app dir. The manifest namespace always names the entry
/// `widget.js` ([WidgetManifest.mainJsPath]) while the engine may boot a
/// different entry ([JsAppEngine.entryFile] — a live-tile entry), so that
/// one path is redirected to the real entry file; every other path
/// (manifest.json, a `files` entry, a relative import target) maps 1:1.
class _AppWidgetFileReader implements WidgetFileReader {
  _AppWidgetFileReader(this._env, {required this.dir, required this.entryFile});

  final ExecutionEnv _env;

  /// Env-relative app directory (`apps/<id>` or a session override).
  final String dir;

  /// The entry file inside [dir] the engine boots.
  final String entryFile;

  String _map(String path) =>
      path == '$dir/widget.js' ? '$dir/$entryFile' : path;

  @override
  Future<String?> readString(String path) async =>
      (await _env.readTextFile(_map(path))).valueOrNull;

  @override
  Future<bool> exists(String path) async =>
      (await _env.exists(_map(path))).valueOrNull ?? false;
}
