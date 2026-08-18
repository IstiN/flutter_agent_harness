// l10n:ignore-file — prototype redesign ships en-only copy for now
import 'dart:async';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The right-side "My Apps" panel for the [WideLayoutShell].
///
/// Structured like the prototype: a header with count, a search bar,
/// filter chips (All/Recent/Created/Pinned), optional weather/timer widget,
/// then a 4-column grid of app tiles grouped into sections, and a
/// "Recent activity" footer.
class AppsPanel extends StatefulWidget {
  const AppsPanel({
    super.key,
    required this.manager,
    this.appsStore,
    this.sessionNamesStore,
  });

  final FlutterSessionManager manager;

  /// App discovery/seeding; null → creates one from the manager's env.
  final AppsStore? appsStore;

  final dynamic sessionNamesStore;

  @override
  State<AppsPanel> createState() => _AppsPanelState();
}

class _AppsPanelState extends State<AppsPanel> {
  final _searchController = TextEditingController();
  late final AppsStore _appsStore;
  List<JsAppInfo> _apps = const [];
  var _loading = true;
  var _filter = _AppFilter.all;

  /// Whether we're on macOS desktop (traffic lights float over content).
  static bool get _isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    _appsStore = widget.appsStore ?? AppsStore(widget.manager.env);
    _searchController.addListener(_onSearchChanged);
    _reloadApps();
    unawaited(_loadCalendar());
    widget.manager.active?.service.fsRevision.addListener(_onFsRevision);
  }

  @override
  void dispose() {
    widget.manager.active?.service.fsRevision.removeListener(_onFsRevision);
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

  /// Today's remaining calendar events for the "Up next" widget.
  List<CalendarEvent> _upcomingEvents = const [];
  var _calendarLoaded = false;

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

  List<JsAppInfo> get _demoApps => _apps.where((a) => a.bundled).toList();
  List<JsAppInfo> get _customApps => _apps.where((a) => !a.bundled).toList();

  List<JsAppInfo> get _filteredApps {
    final query = _searchController.text.trim().toLowerCase();
    final source = switch (_filter) {
      _AppFilter.all => _apps,
      _AppFilter.recent => _apps,
      _AppFilter.created => _customApps,
      _AppFilter.pinned => _apps,
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
      // No active session — can't open an app. Show a hint if a
      // ScaffoldMessenger is reachable (the apps panel lives in the
      // wide shell's nested Navigator, which doesn't have one) —
      // otherwise stay silent.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to a provider first to open apps.',
          ), // l10n:ignore — prototype redesign ships en-only copy for now
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    AppAnalytics.instance.jsAppOpened(
      isDemo: AppsStore.demoAppIds.contains(app.id),
      source: 'apps_panel',
    );
    pushJsApp(context, manager: manager, app: app, source: 'apps_panel');
  }

  // Files / Settings live in the shell sidebar and open the real
  // [FileBrowser] / [SettingsScreen] from there — the apps panel no
  // longer surfaces grey placeholder tiles for them.


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
          // ── Header ───────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              // macOS: extra top padding to clear traffic lights (content
              // extends to the window top — no global 28px strip).
              _isMacOS ? 28 : 16,
              16,
              8,
            ),
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
                const SizedBox(width: 8),
                // "Customize" label like the prototype.
                Text(
                  'Customize',
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
                ),
                const SizedBox(width: 4),
                Icon(Icons.tune, size: 16, color: colors.dim),
              ],
            ),
          ),
          // ── Search bar ───────────────────────────────────────────
          Padding(
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
          ),
          // ── Filter tabs (prototype style: pill highlight, no borders) ──
          Padding(
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
          ),
          // ── Content ──────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _buildContent(colors, theme, isLight),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(FahColors colors, ThemeData theme, bool isLight) {
    final filtered = _filteredApps;
    final query = _searchController.text.trim();

    if (query.isNotEmpty) {
      // Search mode: flat grid of matches.
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.82,
          crossAxisSpacing: 8,
          mainAxisSpacing: 12,
        ),
        itemCount: filtered.length,
        itemBuilder: (context, index) => _AppTile(
          app: filtered[index],
          onTap: () => _openApp(filtered[index]),
        ),
      );
    }

    // Sectioned view matching the prototype. The "Weather placeholder"
    // and "System tiles" rows used to live here as grey stub icons
    // (Calendar, Files, Notes, Maps, Calculator, Settings, Utilities,
    // Travel); they were placeholders that opened nothing or a blank
    // Scaffold. Calendar / Weather / Contacts / Reminders / Health /
    // Maps live in the bundled apps (see AppsStore.demoAppIds) and
    // surface as real tiles under Demo apps below — there's nothing to
    // "stub" here. Focus Timer + Up next are real interactive widgets.
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

        // ── Custom apps section ──────────────────────────────────
        if (_customApps.isNotEmpty) ...[
          _SectionHeader(title: 'Created by you', count: _customApps.length),
          const SizedBox(height: 8),
          _AppGrid(apps: _customApps, onTap: _openApp, showAddTile: true),
          const SizedBox(height: 16),
        ],

        // ── Demo apps section ────────────────────────────────────
        if (_demoApps.isNotEmpty) ...[
          _SectionHeader(title: 'Demo apps', count: _demoApps.length),
          const SizedBox(height: 8),
          _AppGrid(apps: _demoApps, onTap: _openApp),
          const SizedBox(height: 16),
        ],

        // ── All apps fallback ────────────────────────────────────
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

        // ── Recent activity ──────────────────────────────────────
        const Divider(height: 1),
        const SizedBox(height: 8),
        _RecentActivity(colors: colors, theme: theme),
      ],
    );
  }
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
    final dayLabel = isToday
        ? 'Today'
        : '${event.start.month}/${event.start.day}';
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
              // Start/Pause button.
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
              // Reset button.
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

/// 4-column grid of app tiles. When [showAddTile] is true, an "Add app"
/// tile is appended (matching the prototype's "+" tile in the "Created by
/// you" section).
class _AppGrid extends StatelessWidget {
  const _AppGrid({
    required this.apps,
    required this.onTap,
    this.showAddTile = false,
  });

  final List<JsAppInfo> apps;
  final ValueChanged<JsAppInfo> onTap;
  final bool showAddTile;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.82,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
      ),
      itemCount: apps.length + (showAddTile ? 1 : 0),
      itemBuilder: (context, index) {
        if (showAddTile && index == apps.length) {
          return _AddAppTile(colors: colors, theme: theme, isLight: isLight);
        }
        return _AppTile(app: apps[index], onTap: () => onTap(apps[index]));
      },
    );
  }
}

/// The "Add app" tile at the end of the custom apps grid.
class _AddAppTile extends StatelessWidget {
  const _AddAppTile({
    required this.colors,
    required this.theme,
    required this.isLight,
  });

  final FahColors colors;
  final ThemeData theme;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {}, // Placeholder — will open app creation flow
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isLight ? colors.panel : colors.panelAlt,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: colors.border),
            ),
            child: Icon(Icons.add, size: 22, color: colors.indigo),
          ),
          const SizedBox(height: 6),
          Text(
            'Add app',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: colors.indigo,
            ),
          ),
        ],
      ),
    );
  }
}

/// One app tile: rounded-square icon + label.
class _AppTile extends StatelessWidget {
  const _AppTile({required this.app, required this.onTap});

  final JsAppInfo app;
  final VoidCallback onTap;

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
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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

/// The System apps row (Calendar, Files, Notes, Maps, Calculator,
/// Settings, Utilities, Travel) was removed — these were grey placeholder
/// tiles that opened the corresponding system feature or did nothing.
/// Calendar / Weather / Contacts / Reminders / Health / Maps / Calculator
/// live as real JS apps in the apps store and surface under Demo apps
/// below; Files / Settings are real sidebar entries that open
/// [FileBrowser] / [SettingsScreen].

/// Recent activity footer.
class _RecentActivity extends StatelessWidget {
  const _RecentActivity({required this.colors, required this.theme});

  final FahColors colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Recent activity',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.dim,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _ActivityRow(
          icon: Icons.check_circle_outline,
          label: 'Checked Calendar',
          time: 'Just now',
          colors: colors,
          theme: theme,
        ),
        _ActivityRow(
          icon: Icons.folder_open,
          label: 'Opened Files',
          time: '10m ago',
          colors: colors,
          theme: theme,
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.icon,
    required this.label,
    required this.time,
    required this.colors,
    required this.theme,
  });

  final IconData icon;
  final String label;
  final String time;
  final FahColors colors;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colors.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
            ),
          ),
          Text(
            time,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.dim.withValues(alpha: 0.6),
              fontSize: 10,
            ),
          ),
        ],
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
