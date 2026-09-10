// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/asr_service.dart' show AsrTranscriber;
import 'package:fa/services/media_tools.dart' show MediaGateway;
import 'package:fa/services/video_tool.dart' show VideoReader;
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Host side of interactive dynamic messages (issue #102): the session-
/// scoped lifecycle around the agent's `dynamic_message` tool. Owns the
/// widget definitions presented in the CURRENT session, their live JS
/// engines (full installed-app surface, identity = sessionId+widgetId),
/// the event back-channel to the agent, and the graduation of a widget
/// into an installed app.
///
/// Engines boot lazily when a transcript tile first renders (a long
/// session replays without starting every widget at once) and are
/// disposed on session switch/reset — widget state survives in
/// `<session dir>/.widgets/<sessionId>/<widgetId>/storage.json` next to
/// the session file (rides the same iCloud-synced sessions tree).
class DynamicMessagesService extends ChangeNotifier {
  DynamicMessagesService({
    required this.env,
    required Future<void> Function(String text) sendText,
    required String? Function() sessionIdOf,
    required String? Function() sessionFileOf,
    required MediaGateway? Function() mediaGatewayOf,
    required VideoReader? Function() videoReaderOf,
    required Map<String, String> Function() hostSecretsOf,
    required FaLlmHandler? Function() llmHandlerOf,
    required Future<AsrTranscriber?> Function() asrTranscriberOf,
    RequestSecretCallback? resolveHostSecretDefault,
  }) : _sendText = sendText,
       _sessionIdOf = sessionIdOf,
       _sessionFileOf = sessionFileOf,
       _mediaGatewayOf = mediaGatewayOf,
       _videoReaderOf = videoReaderOf,
       _hostSecretsOf = hostSecretsOf,
       _llmHandlerOf = llmHandlerOf,
       _asrTranscriberOf = asrTranscriberOf,
       _resolveHostSecretDefault = resolveHostSecretDefault;

  final ExecutionEnv env;
  final Future<void> Function(String text) _sendText;
  final String? Function() _sessionIdOf;
  final String? Function() _sessionFileOf;

  /// Suppliers resolved per engine boot: the session service owns the
  /// instances and they appear after this construction, so closures beat
  /// captured values. The llm/asr suppliers keep the `jsr.fa.llm*` /
  /// `jsr.fa.asr.*` bridges at full installed-app parity (issue #102 AC6).
  final MediaGateway? Function() _mediaGatewayOf;
  final VideoReader? Function() _videoReaderOf;
  final Map<String, String> Function() _hostSecretsOf;
  final FaLlmHandler? Function() _llmHandlerOf;
  final Future<AsrTranscriber?> Function() _asrTranscriberOf;

  /// Fallback secret requester when a tile supplies none (no build
  /// context outside the transcript): the session's own flow.
  final RequestSecretCallback? _resolveHostSecretDefault;

  /// Last engine-boot failure per widget id — the AC9 error tile renders
  /// it; cleared on a successful boot and on session teardown.
  final Map<String, String> _bootErrors = {};

  /// Widget definitions of the current session, in presentation order.
  final List<DynamicMessageDefinition> widgets = [];

  /// Live engines by widget id; booted lazily by transcript tiles.
  final Map<String, JsAppEngine> _engines = {};
  final Set<String> _booting = {};
  final Set<String> _bootFailed = {};

  /// Per-widget no-UI watchdogs (see [noUiGrace]).
  final Map<String, Timer> _noUiTimers = {};

  /// Presentations made in the CURRENT run — the anti-spam cap (at most
  /// [maxPerRun] per agent turn); reset on every run start.
  final Set<String> _presentedThisRun = {};

  /// Markers presented but not yet placed in the transcript: the agent
  /// service pops one per `dynamic_message` tool-result tile so the widget
  /// renders directly under its tool call.
  final List<DynamicMessageDefinition> _pendingMarkers = [];

  /// At most this many dynamic messages per agent run (host-enforced cap;
  /// the tool's callback declines further presentations in the same run).
  static const int maxPerRun = 3;

  /// The agent-facing event payload cap; longer payloads truncate with an
  /// explicit marker.
  static const int maxEventPayloadChars = 4096;

  /// How long a booted engine may stay without a UI tree before the tile
  /// records a boot error (AC9's malformed-JS half: the runtime logs
  /// syntax errors instead of throwing). Async widgets that fetch before
  /// rendering have this long; the check is a no-op once a tree arrives.
  @visibleForTesting
  static Duration noUiGrace = const Duration(seconds: 10);

  /// The transcript marker role for dynamic widgets (fa_ui renders it
  /// through [FaChatHost.dynamicWidgetTileBuilder]).
  static const String markerRole = 'widget';

  /// The CustomRecord `customType` persisting widget definitions.
  static const String recordType = 'dynamic_widget';

  /// Whether any widget of this session has a live engine (badge).
  bool get hasLive => _engines.isNotEmpty;

  int get liveCount => _engines.length;

  DynamicMessageDefinition? byId(String id) {
    for (final widget in widgets) {
      if (widget.id == id) return widget;
    }
    return null;
  }

  /// The last boot failure message of a widget; null when it boots (or
  /// never tried). The transcript tile renders it in the AC9 error tile.
  String? bootErrorFor(String id) => _bootErrors[id];

  /// Test/golden seam: injects a definition and, optionally, a fake
  /// engine or a boot error — no JS runtime, no session file needed.
  /// Production code never calls this.
  @visibleForTesting
  void debugAdd(
    DynamicMessageDefinition definition, {
    JsAppEngine? engine,
    String? bootError,
  }) {
    widgets.add(definition);
    if (engine != null) _engines[definition.id] = engine;
    if (bootError != null) _bootErrors[definition.id] = bootError;
  }

  @visibleForTesting
  int get liveEngineCount => _engines.length;

  JsAppEngine? engineFor(String id) => _engines[id];

  bool bootFailed(String id) => _bootFailed.contains(id);

  /// Pops the oldest unplaced presentation (transcript insertion order =
  /// tool-call order).
  DynamicMessageDefinition? takePendingMarker() {
    if (_pendingMarkers.isEmpty) return null;
    return _pendingMarkers.removeAt(0);
  }

  /// Run start: a fresh turn gets a fresh presentation budget.
  void onRunStart() => _presentedThisRun.clear();

  /// The `dynamic_message` tool's host callback: persists the definition,
  /// materialises the widget's code (and initial state, once), and queues
  /// the transcript marker. Resolves with the widget id once presented, or
  /// null when declined (cap reached, no session).
  Future<String?> present(DynamicMessageRequest request) async {
    final sessionId = _sessionIdOf();
    final sessionFile = _sessionFileOf();
    if (sessionId == null || sessionFile == null) return null;
    if (_presentedThisRun.length >= maxPerRun) return null;
    final id = 'dm-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _presentedThisRun.add(id);
    await materialise(sessionId: sessionId, request: request, id: id);
    widgets.add(
      DynamicMessageDefinition(
        id: id,
        title: request.title,
        jsSource: request.jsSource,
        initialState: request.initialState,
        heightHint: request.heightHint,
        createdAt: DateTime.now(),
      ),
    );
    _pendingMarkers.add(widgets.last);
    notifyListeners();
    return id;
  }

  /// Rebuilds the session's widgets from a replayed branch: materialises
  /// each definition and returns `(insertIndex, marker)` pairs — one per
  /// `dynamic_widget` record — where insertIndex counts message records
  /// seen before the record on the chain (the marker lands right after the
  /// assistant reply that emitted it).
  Future<List<(int, FaChatMessage)>> adoptBranch(
    List<SessionRecord> records,
  ) async {
    final sessionId = _sessionIdOf();
    if (sessionId == null) return const [];
    final markers = <(int, FaChatMessage)>[];
    var messageCount = 0;
    for (final record in records) {
      if (record is MessageRecord) {
        messageCount++;
        continue;
      }
      if (record is! CustomRecord || record.customType != recordType) {
        continue;
      }
      final data = record.data;
      if (data is! Map) continue;
      final map = Map<String, Object?>.from(data);
      final request = dynamicMessageRequestFromJson(map);
      if (request == null) continue;
      final id = (map['id'] ?? 'dm-replayed').toString();
      // The record may come from an IMPORTED session file: a hostile id
      // must never reach a filesystem path (no separators, no dots —
      // `../` and absolutes cannot encode). Skipped like any other
      // foreign/corrupt record.
      if (!isValidWidgetId(id)) continue;
      try {
        await materialise(sessionId: sessionId, request: request, id: id);
      } on Object {
        // A definition whose code no longer materialises (read-only env,
        // corrupt record) still renders — as an error tile (AC9), so the
        // definition itself must survive the failure.
      }
      final definition = DynamicMessageDefinition(
        id: id,
        title: request.title,
        jsSource: request.jsSource,
        initialState: request.initialState,
        heightHint: request.heightHint,
        createdAt:
            DateTime.tryParse('${map['createdAt'] ?? ''}') ?? DateTime.now(),
        eventCount: (map['eventCount'] as num?)?.toInt() ?? 0,
      );
      widgets.add(definition);
      markers.add((
        messageCount,
        FaChatMessage(role: markerRole, content: definition.title, data: id),
      ));
    }
    if (markers.isNotEmpty) notifyListeners();
    return markers;
  }

  /// Boot (or return) the live engine for a widget tile. Idempotent; a
  /// boot-in-progress or a previous boot failure resolves null (the tile
  /// renders the boot state / error tile instead).
  Future<JsAppEngine?> ensureEngine(
    DynamicMessageDefinition definition, {
    String? locale,
    Map<String, dynamic>? theme,
    Future<RequestSecretResult?> Function(String name, String reason)?
    keyRequestHandler,
  }) async {
    final existing = _engines[definition.id];
    if (existing != null) return existing;
    if (_booting.contains(definition.id)) return null;
    _booting.add(definition.id);
    _bootFailed.remove(definition.id);
    _bootErrors.remove(definition.id);
    JsAppEngine? engine;
    try {
      final store = await AppPermissionsStore.load(env);
      engine = JsAppEngine(
        app: appInfoFor(definition),
        env: env,
        permissions: store.forApp(appInfoFor(definition)).effective(),
        // Full installed-app surface (issue #102 AC6): the same llm/asr
        // backends a JsAppView boots with, sourced from the session.
        llmHandler: _llmHandlerOf(),
        asrTranscriber: await _asrTranscriberOf(),
        mediaGateway: _mediaGatewayOf(),
        videoReader: _videoReaderOf(),
        keysSource: _hostSecretsOf,
        keyRequestHandler: keyRequestHandler ?? _resolveHostSecretDefault,
        hostLocale: locale ?? 'en',
        initialTheme: theme ?? const <String, dynamic>{},
        onEmit: (event, payload) => _handleEmit(definition, event, payload),
      );
      await engine.start();
      _engines[definition.id] = engine;
      // A retry booted clean: drop the stale error so the tile renders
      // the live widget instead of the AC9 error tile.
      _bootFailed.remove(definition.id);
      _bootErrors.remove(definition.id);
      _noUiTimers[definition.id] = Timer(noUiGrace, () {
        unawaited(_failNoUi(definition, engine!));
      });
      notifyListeners();
      return engine;
    } on Object catch (error) {
      // A boot that threw midway still owns a half-started native
      // engine — free it before recording the failure (repeated
      // failures must not leak engines).
      await engine?.dispose();
      AppLog.i(
        'apps',
        'dynamic widget start failed: ${definition.id} — $error',
      );
      _bootFailed.add(definition.id);
      _bootErrors[definition.id] = '$error';
      // Tiles rebuild to show the AC9 error tile.
      notifyListeners();
      return null;
    } finally {
      _booting.remove(definition.id);
    }
  }

  /// The no-UI watchdog: a booted engine that never produced a tree
  /// (malformed script — the runtime logs syntax errors instead of
  /// failing the boot) records the boot error and frees the engine, so
  /// the tile renders the AC9 error tile instead of spinning forever.
  Future<void> _failNoUi(
    DynamicMessageDefinition definition,
    JsAppEngine engine,
  ) async {
    _noUiTimers.remove(definition.id);
    if (_engines[definition.id] != engine) return;
    if (engine.tree.value != null) return;
    AppLog.i('apps', 'dynamic widget produced no UI: ${definition.id}');
    _engines.remove(definition.id);
    _bootFailed.add(definition.id);
    _bootErrors[definition.id] =
        'Widget produced no UI — the script may be invalid or empty.';
    await engine.dispose();
    notifyListeners();
  }

  /// The error tile's explicit retry: clears the cached boot failure
  /// (the only path that does — rebuilds never re-boot a failed widget)
  /// and boots fresh.
  Future<void> retryBoot(
    DynamicMessageDefinition definition, {
    String? locale,
    Map<String, dynamic>? theme,
    Future<RequestSecretResult?> Function(String name, String reason)?
    keyRequestHandler,
  }) async {
    _bootFailed.remove(definition.id);
    _bootErrors.remove(definition.id);
    notifyListeners();
    await ensureEngine(
      definition,
      locale: locale,
      theme: theme,
      keyRequestHandler: keyRequestHandler,
    );
  }

  /// Restarts one widget engine after a permissions change (same rule as
  /// the app view: granted bridges only apply to a fresh boot).
  Future<void> restartEngine(
    DynamicMessageDefinition definition, {
    String? locale,
    Map<String, dynamic>? theme,
    Future<RequestSecretResult?> Function(String name, String reason)?
    keyRequestHandler,
  }) async {
    _noUiTimers.remove(definition.id)?.cancel();
    final old = _engines.remove(definition.id);
    if (old != null) {
      await old.dispose();
    }
    await ensureEngine(
      definition,
      locale: locale,
      theme: theme,
      keyRequestHandler: keyRequestHandler,
    );
    notifyListeners();
  }

  /// The widget event back-channel (AC: interactions flow to the agent as
  /// user messages): `sendText` steers a live run, otherwise it starts a
  /// new turn — the same path inbox mail uses.
  void _handleEmit(
    DynamicMessageDefinition definition,
    String event,
    Map<String, Object?> payload,
  ) {
    var json = jsonEncode(payload);
    if (json.length > maxEventPayloadChars) {
      json = '${json.substring(0, maxEventPayloadChars)}…[truncated]';
    }
    definition.eventCount++;
    unawaited(
      _sendText(
        '[widget ${definition.title}] $event $json',
      ).then((_) => notifyListeners(), onError: (Object _) {}),
    );
  }

  /// Graduates a widget into an installed app (one-tap "save as app"):
  /// writes `apps/<appId>/` with its own manifest + the widget's JS and
  /// COPIES the current storage state — the app then runs standalone and
  /// independent (further widget writes never leak into the app).
  ///
  /// Returns the installed app id, or null when [appId] slugs to an
  /// existing app (the caller pre-fills a fresh id instead).
  Future<String?> saveAsApp(
    DynamicMessageDefinition definition,
    String appId,
  ) async {
    final slug = _slugify(appId);
    if (slug.isEmpty) return null;
    try {
      // exists() resolves Ok(false) on a fresh tree: the guard is on the
      // VALUE (an existing app), never on the check itself.
      if ((await env.exists('apps/$slug/manifest.json')).valueOrNull == true) {
        return null;
      }
      (await env.createDir('apps/$slug')).getOrThrow();
      (await env.writeFile(
        'apps/$slug/manifest.json',
        jsonEncode({
          'id': slug,
          'name': definition.title,
          'description': graduatedDescription(definition.title),
          'version': '1.0.0',
        }),
      )).getOrThrow();
      (await env.writeFile(
        'apps/$slug/widget.js',
        definition.jsSource,
      )).getOrThrow();
      final sessionFile = _sessionFileOf();
      final sessionId = _sessionIdOf();
      if (sessionFile != null && sessionId != null) {
        final source = _widgetDir(sessionFile, sessionId, definition.id);
        final raw = await env.readTextFile('$source/storage.json');
        final text = raw.valueOrNull;
        if (text != null) {
          (await env.writeFile('apps/$slug/storage.json', text)).getOrThrow();
        }
      }
    } on Object {
      // A failed graduation (read-only env, slug collision mid-write)
      // surfaces as "cannot save" in the UI, never as a crash.
      return null;
    }
    return slug;
  }

  /// Serializes unpersisted definitions for the session writer and marks
  /// them persisted (one `dynamic_widget` CustomRecord per presentation).
  List<Map<String, Object?>> drainRecordPayloads() {
    final payloads = <Map<String, Object?>>[];
    for (final widget in widgets) {
      if (widget.persisted) continue;
      widget.persisted = true;
      payloads.add({
        'id': widget.id,
        ...DynamicMessageRequest(
          title: widget.title,
          jsSource: widget.jsSource,
          initialState: widget.initialState,
          heightHint: widget.heightHint,
        ).toJson(),
        'createdAt': widget.createdAt.toIso8601String(),
        'eventCount': widget.eventCount,
      });
    }
    return payloads;
  }

  /// Strict widget-id shape. Ids ride filesystem paths
  /// (`<session dir>/.widgets/<sessionId>/<widgetId>/`), and replayed
  /// records may arrive from an imported session file — so before ANY
  /// path use an id must be a bounded separator-free token (no `/`, no
  /// `.`, no absolutes: traversal cannot encode).
  static final RegExp _widgetIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static bool isValidWidgetId(String id) => _widgetIdPattern.hasMatch(id);

  /// The storage dir for one widget: next to the session file
  /// (`<session dir>/.widgets/<sessionId>/<widgetId>/`), so the sessions
  /// tree carries widget state wherever sessions go. This is the single
  /// chokepoint where widget ids become paths — both components are
  /// validated here.
  static String _widgetDir(
    String sessionFile,
    String sessionId,
    String widgetId,
  ) {
    if (!isValidWidgetId(widgetId)) {
      throw ArgumentError.value(widgetId, 'widgetId', 'not a widget id');
    }
    if (sessionId.isEmpty ||
        sessionId.contains('/') ||
        sessionId.contains('..')) {
      throw ArgumentError.value(sessionId, 'sessionId', 'not a session id');
    }
    final slash = sessionFile.lastIndexOf('/');
    final sessionDirPath = slash <= 0 ? '' : sessionFile.substring(0, slash);
    return '$sessionDirPath/.widgets/$sessionId/$widgetId';
  }

  String? _widgetDirOf(String widgetId) {
    final sessionFile = _sessionFileOf();
    final sessionId = _sessionIdOf();
    if (sessionFile == null || sessionId == null) return null;
    return _widgetDir(sessionFile, sessionId, widgetId);
  }

  /// Writes the widget's code (every time — replay may carry newer source)
  /// and seeds initial state once, ever.
  Future<void> materialise({
    required String sessionId,
    required DynamicMessageRequest request,
    required String id,
  }) async {
    final sessionFile = _sessionFileOf();
    if (sessionFile == null) {
      throw StateError('No session file to host dynamic widgets.');
    }
    final dir = _widgetDir(sessionFile, sessionId, id);
    (await env.createDir(dir)).getOrThrow();
    (await env.writeFile('$dir/widget.js', request.jsSource)).getOrThrow();
    if (request.initialState != null && request.initialState!.isNotEmpty) {
      final storagePath = '$dir/storage.json';
      final raw = await env.readTextFile(storagePath);
      if (raw.valueOrNull == null) {
        (await env.writeFile(
          storagePath,
          jsonEncode(request.initialState),
        )).getOrThrow();
      }
    }
  }

  /// The virtual app behind a widget engine: identity (sessionId,
  /// widgetId), code+storage under the session's own tree.
  JsAppInfo appInfoFor(DynamicMessageDefinition definition) => JsAppInfo(
    id: definition.id,
    name: definition.title,
    description: 'Dynamic message',
    icon: '✦',
    declaredPermissions: const AppPermissions(),
    dirOverride: _widgetDirOf(definition.id),
  );

  /// The app description a widget carries into its graduated app
  /// (manifest + publish sheet).
  static String graduatedDescription(String title) =>
      'Graduated from the "$title" dynamic message.';

  static String _slugify(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Drops everything for the current session (switch/reset/dispose).
  /// Persisted definitions reload from the session records; engines do not
  /// survive a switch.
  Future<void> forgetAll() async {
    _pendingMarkers.clear();
    _presentedThisRun.clear();

    final hadState =
        widgets.isNotEmpty || _engines.isNotEmpty || _bootErrors.isNotEmpty;
    if (!hadState) {
      _bootFailed.clear();
      return;
    }
    widgets.clear();
    for (final timer in _noUiTimers.values) {
      timer.cancel();
    }
    _noUiTimers.clear();
    final engines = List.of(_engines.values);
    _engines.clear();
    _bootFailed.clear();
    _bootErrors.clear();
    for (final engine in engines) {
      await engine.dispose();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _noUiTimers.values) {
      timer.cancel();
    }
    _noUiTimers.clear();
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
    super.dispose();
  }
}

/// The session-scoped definition behind one dynamic message. [eventCount]
/// is mutable (the live badge and the ✦ list read it).
final class DynamicMessageDefinition {
  DynamicMessageDefinition({
    required this.id,
    required this.title,
    required this.jsSource,
    required this.createdAt,
    this.initialState,
    this.heightHint,
    this.eventCount = 0,
  });

  final String id;
  final String title;
  final String jsSource;
  final Map<String, Object?>? initialState;
  final double? heightHint;
  final DateTime createdAt;
  int eventCount;

  /// Transcript index of this widget's marker (updated at insertion; an
  /// external transcript rebuild re-inserts from here).
  int markerIndex = 0;

  /// Set once the definition's `dynamic_widget` record is on the chain.
  bool persisted = false;
}

/// Parses a persisted `dynamic_widget` record payload back into a request
/// (replay materialisation). Null on a foreign/corrupt payload.
DynamicMessageRequest? dynamicMessageRequestFromJson(
  Map<String, Object?> data,
) {
  final title = data['title'];
  final jsSource = data['jsSource'];
  if (title is! String || jsSource is! String) return null;
  final state = data['initialState'];
  final height = data['heightHint'];
  return DynamicMessageRequest(
    title: title,
    jsSource: jsSource,
    initialState: state is Map<String, Object?> ? state : null,
    heightHint: height is num ? height.toDouble() : null,
  );
}
