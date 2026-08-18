// l10n:ignore-file — prototype redesign ships en-only copy for now
import 'dart:async';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/pinned_apps_store.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Layout mode for [MyAppsShell].
///
/// * [panel] — right-side panel of the wide-layout shell. Compact spacing,
///   no top app bar (the shell provides the chrome).
/// * [mobile] — full-screen home on narrow layouts (replaces the old
///   iOS-grid launcher). The shell overlay (chat sheet) sits above this
///   in a Stack — `MyAppsShell` only owns the apps surface itself.
enum MyAppsShellMode { panel, mobile }

/// The shared "My Apps" surface used on every layout: the wide-layout
/// shell's right-side panel AND the mobile home. One widget tree, one
/// header (count + Customize), one search field, one set of filter chips
/// (All / Recent / Created with ★ / Pinned), and the same sections
/// (Up next, Focus Timer, Created by you, Demo apps).
///
/// This unifies the previous [AppsPanel] (panel-only, search + sections)
/// and the old [AppLauncherScreen] grid (mobile-only, drag-and-drop with
/// folders). Drag-and-drop / folders / reorder are NOT carried over — the
/// 1000-line launcher logic was a mobile-only thing that doesn't fit the
/// unified layout (and is an obvious follow-up: add a section-level
/// reorder if/when it's wanted). Apps themselves stay 1-tap-to-launch.
class MyAppsShell extends StatefulWidget {
  const MyAppsShell({
    super.key,
    required this.manager,
    this.appsStore,
    this.pinnedStore,
    this.mode = MyAppsShellMode.panel,
  });

  final FlutterSessionManager manager;

  /// App discovery/seeding; null → creates one from the manager's env.
  final AppsStore? appsStore;

  /// Pinned-ids store; null → an in-memory store (no persistence,
  /// useful in widget tests + golden screenshots).
  final PinnedAppsStore? pinnedStore;

  /// Layout mode (panel / mobile). See [MyAppsShellMode].
  final MyAppsShellMode mode;

  @override
  State<MyAppsShell> createState() => _MyAppsShellState();
}

class _MyAppsShellState extends State<MyAppsShell> {
  final _searchController = TextEditingController();
  late final AppsStore _appsStore;
  late final PinnedAppsStore _pinnedStore;
  List<JsAppInfo> _apps = const [];
  var _loading = true;
  var _filter = _AppFilter.all;

  /// Today's remaining calendar events for the "Up next" widget.
  List<CalendarEvent> _upcomingEvents = const [];
  var _calendarLoaded = false;

  /// Whether we're on macOS desktop (traffic lights float over content).
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _appsStore = widget.appsStore ?? AppsStore(widget.manager.env);
    _pinnedStore = widget.pinnedStore ?? PinnedAppsStore(widget.manager.env);
    _pinnedStore.addListener(_onPinnedChanged);
    _searchController.addListener(_onSearchChanged);
    _reloadApps();
    unawaited(_loadCalendar());
    unawaited(_pinnedStore.load());
    widget.manager.active?.service.fsRevision.addListener(_onFsRevision);
  }

  void _onPinnedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MyAppsShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager) {
      oldWidget.manager.active?.service.fsRevision.removeListener(_onFsRevision);
      widget.manager.active?.service.fsRevision.addListener(_onFsRevision);
      _reloadApps();
    }
  }

  @override
  void dispose() {
    widget.manager.active?.service.fsRevision.removeListener(_onFsRevision);
    _pinnedStore.removeListener(_onPinnedChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  void _onFsRevision() {
    if (mounted) _reloadApps();
  }

  Future<void> _reloadApps() async {
    try {
      final apps = await _appsStore.listApps();
      if (mounted) {
        setState(() {
          _apps = apps;
          _loading = false;
        });
      }
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadCalendar() async {
    try {
      final calendar = createCalendarService();
      if (!await calendar.isAvailable) {
        if (mounted) setState(() => _calendarLoaded = true);
        return;
      }
      final now = DateTime.now();
      final endOfDay = DateTime(now.year, now.month, now.day, 23, 59, 59);
      final events = await calendar.events(start: now, end: endOfDay);
      if (mounted) {
        setState(() {
          _upcomingEvents = events.take(3).toList();
          _calendarLoaded = true;
        });
      }
    } on Object {
      if (mounted) setState(() => _calendarLoaded = true);
    }
  }

  /// Bundled demos are the apps that ship with the app — they're seeded
  /// from `assets/apps/` into the env on first run. The manifest flag is
  /// preserved across that seed, but AppsStore reads manifests back with
  /// `bundled: false` (it doesn't know which seed a given app came from),
  /// so the canonical "is this a demo" check is the id against
  /// [AppsStore.demoAppIds]. We honour the manifest flag too — third-party
  /// apps that mark themselves bundled still surface as demos.
  bool _isDemo(JsAppInfo app) =>
      app.bundled || AppsStore.demoAppIds.contains(app.id);

  List<JsAppInfo> get _demoApps =>
      _apps.where(_isDemo).toList();
  List<JsAppInfo> get _customApps =>
      _apps.where((a) => !_isDemo(a)).toList();

  List<JsAppInfo> get _filteredApps {
    final query = _searchController.text.trim().toLowerCase();
    final source = switch (_filter) {
      _AppFilter.all => _apps,
      _AppFilter.recent => _apps,
      _AppFilter.created => _customApps,
      _AppFilter.pinned => [
        for (final a in _apps)
          if (_pinnedStore.isPinned(a.id)) a,
      ],
    };
    if (query.isEmpty) return source.toList();
    return source
        .where(
          (a) =>
              a.name.toLowerCase().contains(query) ||
              a.id.toLowerCase().contains(query) ||
              a.description.toLowerCase().contains(query),
        )
        .toList();
  }

  void _openApp(JsAppInfo app) {
    final manager = widget.manager;
    if (manager.active?.service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to a provider first to open apps.',
          ), // l10n:ignore — prototype redesign ships en-only copy for now
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final isDemo = _isDemo(app);
    final source = widget.mode == MyAppsShellMode.mobile
        ? 'launcher'
        : 'apps_panel';
    AppAnalytics.instance.jsAppOpened(isDemo: isDemo, source: source);
    pushJsApp(context, manager: manager, app: app, source: source);
  }

  /// Long-press handler on a tile — toggles the Pinned filter for that
  /// app. The store notifies; setState runs via [_onPinnedChanged].
  void _togglePin(String appId) {
    unawaited(_pinnedStore.toggle(appId));
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final bg = isLight ? colors.bg : colors.panel;
    return Container(
      color: bg,
      child: Column(
        children: [
          _buildHeader(colors, theme),
          _buildSearch(colors, isLight),
          _buildFilters(colors, theme),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _buildContent(colors, theme, isLight),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(FahColors colors, ThemeData theme) {
    // Mobile owns its own app bar (the shell pushes a MaterialApp with
    // its own title), so the mobile header here is the simple in-content
    // row only; panel uses the same row plus the macOS top-padding
    // clearance. No Customize affordance — there was nothing to wire it
    // to, and a non-functional link is worse than no link.
    final topPad = widget.mode == MyAppsShellMode.panel && _isMacOS
        ? 28.0
        : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topPad, 16, 8),
      child: Row(
        children: [
          Text(
            'My Apps',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Text(
            '${_apps.length}',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch(FahColors colors, bool isLight) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, size: 18),
          hintText: 'Search apps, files, and more…',
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: colors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: colors.indigo, width: 1.2),
          ),
          filled: true,
          fillColor: isLight ? colors.panel : colors.panelAlt,
        ),
      ),
    );
  }

  Widget _buildFilters(FahColors colors, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final filter in _AppFilter.values)
              _FilterTab(
                label: filter.label,
                selected: _filter == filter,
                onTap: () => setState(() => _filter = filter),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(FahColors colors, ThemeData theme, bool isLight) {
    final filtered = _filteredApps;
    final query = _searchController.text.trim();

    if (query.isNotEmpty) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: _gridDelegateFor(),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final app = filtered[index];
          return _AppTile(
            app: app,
            onTap: () => _openApp(app),
            pinned: _pinnedStore.isPinned(app.id),
            onLongPress: () => _togglePin(app.id),
          );
        },
      );
    }

    // The non-search view: widgets first, then apps. The apps section
    // depends on the active filter — Pinned / Created / All show
    // different sections; Recent is the same as All (recent opens live
    // with the agent and would otherwise need a per-app open-history).
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // ── Up next (real calendar events) ───────────────────────
        if (_calendarLoaded && _upcomingEvents.isNotEmpty) ...[
          _UpNextWidget(
            colors: colors,
            theme: theme,
            isLight: isLight,
            events: _upcomingEvents,
          ),
          const SizedBox(height: 12),
        ],
        // ── Focus Timer (real interactive 25-min pomodoro) ───────
        _FocusTimerWidget(colors: colors, theme: theme, isLight: isLight),
        const SizedBox(height: 16),

        // ── Pinned filter: one flat section of pinned apps ──────
        if (_filter == _AppFilter.pinned) ...[
          if (filtered.isEmpty)
            _EmptyState(
              message: 'Nothing pinned yet.\nLong-press an app tile to pin it.',
              colors: colors,
              theme: theme,
            )
          else ...[
            _SectionHeader(title: 'Pinned', count: filtered.length),
            const SizedBox(height: 8),
            _AppGrid(
              apps: filtered,
              onTap: _openApp,
              gridDelegate: _gridDelegateFor(),
              onLongPress: (app) => _togglePin(app.id),
              pinnedResolver: (app) => _pinnedStore.isPinned(app.id),
            ),
            const SizedBox(height: 16),
          ],
        ]
        // ── Created filter: only custom apps ─────────────────────
        else if (_filter == _AppFilter.created) ...[
          if (_customApps.isEmpty)
            _EmptyState(
              message:
                  'No custom apps yet.\nAsk Fa to build one in the chat.',
              colors: colors,
              theme: theme,
            )
          else ...[
            _SectionHeader(
              title: 'Created by you',
              count: _customApps.length,
            ),
            const SizedBox(height: 8),
            _AppGrid(
              apps: _customApps,
              onTap: _openApp,
              gridDelegate: _gridDelegateFor(),
              onLongPress: (app) => _togglePin(app.id),
              pinnedResolver: (app) => _pinnedStore.isPinned(app.id),
            ),
            const SizedBox(height: 16),
          ],
        ]
        // ── Default (All / Recent): both sections ───────────────
        else ...[
          if (_customApps.isNotEmpty) ...[
            _SectionHeader(
              title: 'Created by you',
              count: _customApps.length,
            ),
            const SizedBox(height: 8),
            _AppGrid(
              apps: _customApps,
              onTap: _openApp,
              gridDelegate: _gridDelegateFor(),
              onLongPress: (app) => _togglePin(app.id),
              pinnedResolver: (app) => _pinnedStore.isPinned(app.id),
            ),
            const SizedBox(height: 16),
          ],
          if (_demoApps.isNotEmpty) ...[
            _SectionHeader(title: 'Demo apps', count: _demoApps.length),
            const SizedBox(height: 8),
            _AppGrid(
              apps: _demoApps,
              onTap: _openApp,
              gridDelegate: _gridDelegateFor(),
              onLongPress: (app) => _togglePin(app.id),
              pinnedResolver: (app) => _pinnedStore.isPinned(app.id),
            ),
            const SizedBox(height: 16),
          ],
        ],

        // ── All apps fallback (when no apps at all) ──────────────
        if (_customApps.isEmpty && _demoApps.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No apps yet.\nAsk Fa to build one!',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
              ),
            ),
          ),
      ],
    );
  }

  /// Mobile home has more horizontal space (a typical phone is 4 columns,
  /// the panel is 4 columns too at its default 380 px). Keep them equal —
  /// any column-count tuning belongs to a later design pass.
  SliverGridDelegate _gridDelegateFor() =>
      const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.82,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
      );
}

enum _AppFilter {
  all,
  recent,
  created,
  pinned;

  String get label => switch (this) {
    all => 'All',
    recent => 'Recent',
    created => 'Created with ★',
    pinned => 'Pinned',
  };
}

/// A text filter tab matching the prototype: selected gets a light indigo
/// pill background with dark text; unselected is plain gray text.
class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? (theme.brightness == Brightness.light
                      ? const Color(0xFFEEF2FF)
                      : colors.panelAlt)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: selected ? colors.text : colors.dim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Up next" section — today's remaining events from the real system
/// calendar (EventKit via [CalendarApi]). Hidden when no events remain.
class _UpNextWidget extends StatelessWidget {
  const _UpNextWidget({
    required this.colors,
    required this.theme,
    required this.isLight,
    required this.events,
  });

  final FahColors colors;
  final ThemeData theme;
  final bool isLight;
  final List<CalendarEvent> events;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLight ? colors.panel : colors.panelAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Up next',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.dim,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < events.length; i++) ...[
            _EventRow(
              time: _formatTime(events[i].start),
              title: events[i].title,
              subtitle: _formatEventTime(events[i]),
              colors: colors,
              theme: theme,
            ),
            if (i < events.length - 1) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }

  static String _formatEventTime(CalendarEvent event) {
    final start = _formatTime(event.start);
    final end = _formatTime(event.end);
    final now = DateTime.now();
    final isToday =
        event.start.year == now.year &&
        event.start.month == now.month &&
        event.start.day == now.day;
    final dayLabel = isToday ? 'Today' : '${event.start.month}/${event.start.day}';
    return '$dayLabel, $start - $end';
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.time,
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.theme,
  });

  final String time;
  final String title;
  final String subtitle;
  final FahColors colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          time,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.dim,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.dim,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Interactive Focus Timer — a real 25-minute pomodoro with start/pause/reset.
class _FocusTimerWidget extends StatefulWidget {
  const _FocusTimerWidget({
    required this.colors,
    required this.theme,
    required this.isLight,
  });

  final FahColors colors;
  final ThemeData theme;
  final bool isLight;

  @override
  State<_FocusTimerWidget> createState() => _FocusTimerWidgetState();
}

class _FocusTimerWidgetState extends State<_FocusTimerWidget> {
  static const _totalSeconds = 25 * 60; // 25:00
  var _remainingSeconds = _totalSeconds;
  Timer? _timer;
  var _running = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
    } else {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_remainingSeconds <= 0) {
          _timer?.cancel();
          setState(() {
            _running = false;
            _remainingSeconds = _totalSeconds;
          });
          return;
        }
        setState(() => _remainingSeconds--);
      });
      setState(() => _running = true);
    }
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _running = false;
      _remainingSeconds = _totalSeconds;
    });
  }

  String get _display {
    final m = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final theme = widget.theme;
    final isLight = widget.isLight;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLight ? colors.panel : colors.panelAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Focus Timer',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.dim,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _display,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: _running ? colors.indigo : colors.pending,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                onTap: _toggle,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _running
                        ? colors.pending.withValues(alpha: 0.15)
                        : colors.indigo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _running ? Icons.pause : Icons.play_arrow,
                        size: 16,
                        color: _running ? colors.pending : colors.indigo,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _running ? 'Pause' : 'Start',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _running ? colors.pending : colors.indigo,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _reset,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Icon(Icons.replay, size: 16, color: colors.dim),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Section header with count.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.dim,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          '$count',
          style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
        ),
      ],
    );
  }
}

/// 4-column grid of app tiles.
class _AppGrid extends StatelessWidget {
  const _AppGrid({
    required this.apps,
    required this.onTap,
    required this.gridDelegate,
    this.onLongPress,
    this.pinnedResolver,
  });

  final List<JsAppInfo> apps;
  final ValueChanged<JsAppInfo> onTap;
  final SliverGridDelegate gridDelegate;

  /// Long-press handler for every tile in this grid. When set, every
  /// tile gets a long-press gesture (pin toggle, typically).
  final ValueChanged<JsAppInfo>? onLongPress;

  /// Per-app "is pinned?" lookup. When set, every tile gets a pin
  /// badge if the resolver returns true.
  final bool Function(JsAppInfo)? pinnedResolver;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: gridDelegate,
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _AppTile(
          app: app,
          onTap: () => onTap(app),
          pinned: pinnedResolver?.call(app) ?? false,
          onLongPress:
              onLongPress == null ? null : () => onLongPress!(app),
        );
      },
    );
  }
}

/// One app tile: rounded-square icon + label.
class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.onTap,
    this.pinned = false,
    this.onLongPress,
  });

  final JsAppInfo app;
  final VoidCallback onTap;

  /// Whether this tile's app is currently pinned. Renders a small pin
  /// badge on the icon — the only visible affordance of the Pinned
  /// filter when the user is on All / Demo apps / Created by you.
  final bool pinned;

  /// Long-press → toggle pin. Null disables the gesture (search mode).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    final service = context
        .dependOnInheritedWidgetOfExactType<ManagerScope>()
        ?.manager
        .active
        ?.service;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isLight ? colors.panelAlt : colors.panel,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: colors.border),
                ),
                child: Center(
                  child: service != null
                      ? AppIcon(app: app, env: service.env, size: 24)
                      : const Icon(Icons.apps, size: 22),
                ),
              ),
              if (pinned)
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 0, right: 0),
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: colors.indigo,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isLight ? colors.bg : colors.panel,
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.push_pin,
                          size: 8,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            app.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: colors.dim,
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-state placeholder when a filter or section has no apps — keeps
/// the panel from collapsing to nothing while still telling the user
/// what action would surface apps (e.g. "long-press to pin").
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.colors,
    required this.theme,
  });

  final String message;
  final FahColors colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
        ),
      ),
    );
  }
}

/// Inherited widget so [_AppTile] can access the session manager for AppIcon.
class ManagerScope extends InheritedWidget {
  const ManagerScope({super.key, required this.manager, required super.child});

  final FlutterSessionManager manager;

  static ManagerScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ManagerScope>();

  @override
  bool updateShouldNotify(ManagerScope oldWidget) =>
      manager != oldWidget.manager;
}