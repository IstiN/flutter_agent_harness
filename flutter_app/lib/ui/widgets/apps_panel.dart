import 'dart:async';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// A compact apps panel for the right side of the [WideLayoutShell].
///
/// Features a search bar, filter chips (All / Demo / Custom), and a 4-column
/// grid of app tiles (icon + name). This is NOT the full iOS-style launcher
/// — it's a simpler, filterable grid designed for the side panel, matching
/// the prototype's "My Apps" section.
class AppsPanel extends StatefulWidget {
  const AppsPanel({
    super.key,
    required this.manager,
    this.appsStore,
    this.sessionNamesStore,
  });

  final FlutterSessionManager manager;

  /// App discovery/seeding; tests inject one with canned assets.
  final AppsStore? appsStore;

  final dynamic sessionNamesStore;

  @override
  State<AppsPanel> createState() => _AppsPanelState();
}

class _AppsPanelState extends State<AppsPanel> {
  final _searchController = TextEditingController();
  List<JsAppInfo> _apps = const [];
  var _loading = true;
  var _filter = _AppFilter.all;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _reloadApps();
    // Listen for fsRevision bumps so agent-created apps appear live.
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
    final store = widget.appsStore;
    if (store == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final apps = await store.listApps();
      if (mounted) setState(() {
        _apps = apps;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<JsAppInfo> get _filteredApps {
    final query = _searchController.text.trim().toLowerCase();
    return _apps.where((app) {
      if (_filter == _AppFilter.demo && !app.bundled) return false;
      if (_filter == _AppFilter.custom && app.bundled) return false;
      if (query.isEmpty) return true;
      return app.name.toLowerCase().contains(query) ||
          app.id.toLowerCase().contains(query) ||
          app.description.toLowerCase().contains(query);
    }).toList();
  }

  void _openApp(JsAppInfo app) {
    final manager = widget.manager;
    AppAnalytics.instance.jsAppOpened(
      isDemo: AppsStore.demoAppIds.contains(app.id),
      source: 'apps_panel',
    );
    pushJsApp(
      context,
      manager: manager,
      app: app,
      source: 'apps_panel',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    return Container(
      color: isLight ? colors.bg : colors.panel,
      child: Column(
        children: [
          // Header.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.dim,
                  ),
                ),
              ],
            ),
          ),
          // Search bar.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Search apps…',
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
          // Filter chips.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                for (final filter in _AppFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(filter.label),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                      showCheckmark: false,
                      padding: EdgeInsets.zero,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // App grid.
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _filteredApps.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _searchController.text.isEmpty
                                ? 'No apps yet.\nAsk Fa to build one!'
                                : 'No apps match your search.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.dim,
                            ),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          childAspectRatio: 0.82,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = _filteredApps[index];
                          return _AppTile(
                            app: app,
                            onTap: () => _openApp(app),
                          );
                        },
                      ),
          ),
          // System tiles (Settings, Files) at the bottom.
          const Divider(height: 1),
          _SystemTile(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: () => _openSettings(),
          ),
          _SystemTile(
            icon: Icons.folder_outlined,
            label: 'Files',
            onTap: () => _openFiles(),
          ),
        ],
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const _PlaceholderPage(title: 'Settings'),
      ),
    );
  }

  void _openFiles() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const _PlaceholderPage(title: 'Files'),
      ),
    );
  }
}

enum _AppFilter {
  all,
  demo,
  custom;

  String get label => switch (this) {
        all => 'All',
        demo => 'Demo',
        custom => 'Custom',
      };
}

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
                  ? AppIcon(
                      app: app,
                      env: service.env,
                      size: 24,
                    )
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

class _SystemTile extends StatelessWidget {
  const _SystemTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.dim),
            const SizedBox(width: 12),
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.dim,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: colors.borderBright,
            ),
          ],
        ),
      ),
    );
  }
}

/// Inherited widget so [_AppTile] can access the session manager for AppIcon.
class ManagerScope extends InheritedWidget {
  const ManagerScope({
    super.key,
    required this.manager,
    required super.child,
  });

  final FlutterSessionManager manager;

  static ManagerScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ManagerScope>();

  @override
  bool updateShouldNotify(ManagerScope oldWidget) =>
      manager != oldWidget.manager;
}

/// Simple placeholder for Settings/Files routes pushed within the apps panel.
class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(child: Text(title)),
    );
  }
}
