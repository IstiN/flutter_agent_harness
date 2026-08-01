// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_map/flutter_map.dart' show TileProvider;
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_theme.dart';
import 'package:fa/ui/app_theme.dart';

/// Engine factory behind [AppTileHost]; tests and goldens inject a fake
/// engine emitting a deterministic tree, the default builds a real
/// [JsAppEngine] on the app's tile entry file ([JsTileWidgetInfo.entry]).
typedef TileEngineFactory =
    JsAppEngine Function({
      required JsAppInfo app,
      required ExecutionEnv env,
      required AppPermissions permissions,
      required Map<String, dynamic> initialTheme,
    });

/// Live launcher tile for one JS app: runs the app's tile entry
/// (`widget_tile.js` by default — the manifest's `"widget"` section, see
/// [JsTileWidgetInfo]) in its own [JsAppEngine] and renders the resulting
/// tree inside the home-grid cell instead of the static icon + label.
///
/// v1 tiles are display-only: any UI event from the tile tree (a tap on any
/// interactive node) opens the full app via [onOpen] — the same contract as
/// iOS home-screen widgets. Long-press drag & drop keeps working because the
/// launcher wraps the tile in its own `LongPressDraggable`.
///
/// The engine restarts on [fsRevision] bumps (600 ms debounce, same as
/// [JsAppView]) so agent edits show up live, follows the host theme via
/// `jsr.theme`, and — when the manifest sets `refreshSeconds` — gets a
/// host-side `tile.refresh` event on that cadence. Tiles are live only while
/// the launcher is visible; the engine dies with the host widget.
class AppTileHost extends StatefulWidget {
  const AppTileHost({
    super.key,
    required this.app,
    required this.env,
    required this.onOpen,
    this.permissionsStore,
    this.fsRevision,
    this.engineFactory,
    this.mapTileProvider,
  });

  /// Integration tests (real-agent E2E) set this to let REAL engines boot
  /// under the test binding — they clean engines up explicitly instead of
  /// relying on the test-fallback shortcut. Defaults to false: unit and
  /// golden tests never boot native engines accidentally.
  static bool allowEnginesInTests = false;

  /// The app whose tile this hosts; [JsAppInfo.tileWidget] must be non-null.
  final JsAppInfo app;

  /// The shared sandbox env the tile entry and storage live in.
  final ExecutionEnv env;

  /// Opens the full app — called on any UI event from the tile tree.
  final VoidCallback onOpen;

  /// Permission overrides; `null` loads the store from [env] on each
  /// (re)start (the launcher does not hold one).
  final AppPermissionsStore? permissionsStore;

  /// Bumped when the agent edits files (AgentService.fsRevision) — the tile
  /// reloads itself so agent-written code shows up live.
  final ValueNotifier<int>? fsRevision;

  /// Test seam: substitutes the tile engine (see [TileEngineFactory]).
  final TileEngineFactory? engineFactory;

  /// Optional tile provider for `map` nodes — tests inject an offline
  /// provider; null uses the runtime default (OSM over the network).
  final TileProvider? mapTileProvider;

  @override
  State<AppTileHost> createState() => _AppTileHostState();
}

class _AppTileHostState extends State<AppTileHost> {
  /// True under `flutter test`. A real flutter_js engine spawns periodic
  /// native-bridge timers that outlive the widget tree and trip the test
  /// binding's "Timer still pending" invariant, so under tests the tile
  /// renders the icon fallback UNLESS the test injects an explicit
  /// [AppTileHost.engineFactory] (golden/tile tests do — they still
  /// exercise the real render path with a fake engine) or opts into real
  /// engines via [AppTileHost.allowEnginesInTests] (integration tests).
  ///
  /// Detected by the binding's class name: `flutter test` installs an
  /// (Automated/Live)TestWidgetsFlutterBinding. No `dart:io` (web-safe);
  /// the `FLUTTER_TEST` dart-define is NOT set by current Flutter, and
  /// release builds never run under a test binding anyway.
  static bool get _kFlutterTest => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  JsAppEngine? _engine;
  Object? _startError;
  Timer? _reloadDebounce;
  Timer? _refreshTimer;
  int _lastFsRevision = -1;

  /// The last theme map handed to the engine (JSON-encoded for cheap
  /// change detection in [didChangeDependencies]) — same pattern as
  /// [JsAppView].
  String? _themeJson;

  @override
  void initState() {
    super.initState();
    widget.fsRevision?.addListener(_onFsRevision);
    unawaited(_restart());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs before the first build and again on every ambient theme change:
    // push live theme updates into the running tile (`jsr._onThemeChange`).
    final next = jsonEncode(jsThemeMap(context));
    if (next == _themeJson) return;
    _themeJson = next;
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.updateTheme(jsonDecode(next) as Map<String, dynamic>));
    }
  }

  @override
  void didUpdateWidget(AppTileHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fsRevision != widget.fsRevision) {
      oldWidget.fsRevision?.removeListener(_onFsRevision);
      widget.fsRevision?.addListener(_onFsRevision);
    }
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_onFsRevision);
    _reloadDebounce?.cancel();
    _refreshTimer?.cancel();
    // Immediate: the process-wide lifecycle lock (JsAppEngine) orders this
    // native release before any new engine's native context creation; the
    // runtime's own `_isLive` guard no-ops evaluations queued behind it.
    unawaited(_engine?.dispose() ?? Future.value());
    super.dispose();
  }

  void _onFsRevision() {
    final revision = widget.fsRevision?.value ?? 0;
    if (revision == _lastFsRevision) return;
    _lastFsRevision = revision;
    // Debounce: agent edits often write manifest + tile entry back to back.
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(_restartIfAppChanged());
    });
  }

  /// The content signature of this app's code files (manifest + tile
  /// entry) at the last engine start — the tile restarts ONLY when its
  /// own app changed. Without this, EVERY agent `write` anywhere bumped
  /// fsRevision and restarted every tile engine — dozens of native JS
  /// context create/release cycles per minute, which is exactly the churn
  /// that made the native address-reuse crash probable (TestFlight
  /// SIGSEGV).
  String _appSignature = '';

  Future<String> _readAppSignature() async {
    final manifest = (await widget.env.readTextFile(
      widget.app.manifestPath,
    )).valueOrNull;
    final entry = (await widget.env.readTextFile(
      widget.app.tileWidgetPath,
    )).valueOrNull;
    return '${manifest?.length}:${entry?.length}:${manifest?.hashCode}:${entry?.hashCode}';
  }

  Future<void> _restartIfAppChanged() async {
    final signature = await _readAppSignature();
    if (!mounted || signature == _appSignature) return;
    await _restart();
  }

  /// Fires one `tile.refresh` event on [engine], unless it was meanwhile
  /// replaced or the host went away. The native use-after-free class of
  /// bugs is addressed at the source: every engine start/dispose is
  /// serialized process-wide (see [JsAppEngine]).
  void _fireTileRefresh(JsAppEngine engine) {
    if (!mounted || !identical(_engine, engine)) return;
    unawaited(engine.callEvent('tile.refresh', const {}));
  }

  Future<void> _restart() async {
    // Yield one microtask (same trick as JsAppView): on the first call this
    // lets didChangeDependencies run first and record _themeJson, so the
    // engine boots with the real theme instead of an empty map.
    await Future<void>.value();
    if (!mounted) return;
    final themeJson = _themeJson;
    final initialTheme = themeJson == null
        ? jsThemeMap(context)
        : jsonDecode(themeJson) as Map<String, dynamic>;
    final old = _engine;
    setState(() {
      _engine = null;
      _startError = null;
    });
    _refreshTimer?.cancel();
    _refreshTimer = null;
    // Disposed immediately — the process-wide lifecycle lock (JsAppEngine)
    // orders this native release before any new engine's native context is
    // created; a delayed release is exactly what used to free a REUSED
    // context address out from under the next engine.
    if (old != null) await old.dispose();
    // No real JS engines under `flutter test` without an explicit factory —
    // show the icon fallback instead (see [_kFlutterTest]); integration
    // tests opt into real engines via [allowEnginesInTests].
    if (_kFlutterTest &&
        !AppTileHost.allowEnginesInTests &&
        widget.engineFactory == null) {
      if (mounted) {
        setState(() => _startError = StateError('flutter test'));
      }
      return;
    }
    try {
      final store =
          widget.permissionsStore ?? await AppPermissionsStore.load(widget.env);
      if (!mounted) return;
      final effective = store.forApp(widget.app).effective();
      final engine =
          widget.engineFactory?.call(
            app: widget.app,
            env: widget.env,
            permissions: effective,
            initialTheme: initialTheme,
          ) ??
          JsAppEngine(
            app: widget.app,
            env: widget.env,
            permissions: effective,
            entryFile:
                widget.app.tileWidget?.entry ?? JsTileWidgetInfo.defaultEntry,
            initialTheme: initialTheme,
          );
      try {
        await engine.start();
      } on Object {
        // A half-started engine leaks its native-bridge timers — always
        // dispose it before surfacing the failure as the icon fallback.
        await engine.dispose();
        rethrow;
      }
      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() => _engine = engine);
      // Restart tiles ONLY when their own app changed afterwards (see
      // [_restartIfAppChanged]) — record the signature the new engine
      // booted from.
      _appSignature = await _readAppSignature();
      final refreshSeconds = widget.app.tileWidget?.refreshSeconds;
      if (refreshSeconds != null) {
        _refreshTimer = Timer.periodic(Duration(seconds: refreshSeconds), (_) {
          _fireTileRefresh(engine);
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _startError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Semantics(
      label: widget.app.name,
      button: true,
      child: Container(
        decoration: BoxDecoration(
          color: colors.panelAlt,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: _buildBody(Theme.of(context)),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final error = _startError;
    if (error != null) {
      // The tile entry failed to boot (missing file, JS error) — fall back
      // to the app icon so the cell never goes blank.
      return Center(
        child: AppIcon(app: widget.app, env: widget.env, size: 32),
      );
    }
    final engine = _engine;
    if (engine == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: engine.tree,
      builder: (context, tree, _) {
        if (tree == null) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final renderer = JsonWidgetRenderer(
          theme: JsonWidgetTheme.fromAccent(
            theme.colorScheme.primary,
            brightness: theme.brightness,
          ),
          mapTileProvider: widget.mapTileProvider,
          // 3D scenes render in tiles too (display-only — no tap picking:
          // any tap opens the full app).
          js3dHost: createJs3dHost(),
          // Display-only tile: any UI event opens the full app.
          onEvent: (actionId, payload) => widget.onOpen(),
        );
        return renderer.build(tree, context);
      },
    );
  }
}
