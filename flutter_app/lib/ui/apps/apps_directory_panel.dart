// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/apps/app_launcher_controller.dart';
import 'package:fa/ui/apps/running_apps_dock.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv;

/// The desktop Apps directory from the messenger PoC: a glass capsule
/// toolbar (the sidebar chrome language), then My Apps, Widgets Catalog,
/// and the real currently-running app row.
final class AppsDirectoryPanel extends StatefulWidget {
  const AppsDirectoryPanel({
    super.key,
    required this.controller,
    required this.appsStore,
    required this.runningApps,
    required this.activeAppId,
    required this.env,
    required this.onOpenRunning,
    this.showSearch = true,
    this.topPadding = 0,
  });

  final AppLauncherController controller;
  final AppsStore appsStore;
  final List<JsAppInfo> runningApps;
  final String? activeAppId;
  final ExecutionEnv env;
  final ValueChanged<JsAppInfo> onOpenRunning;
  final bool showSearch;
  final double topPadding;

  @override
  State<AppsDirectoryPanel> createState() => _AppsDirectoryPanelState();
}

final class _AppsDirectoryPanelState extends State<AppsDirectoryPanel> {
  int? _installedCount;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCount());
  }

  @override
  void didUpdateWidget(covariant AppsDirectoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appsStore != widget.appsStore) unawaited(_loadCount());
  }

  Future<void> _loadCount() async {
    final apps = await widget.appsStore.listApps();
    if (!mounted) return;
    setState(() => _installedCount = apps.length);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    return ColoredBox(
      key: const ValueKey('appsDirectory'),
      color: tokens.direction == FaVisualDirection.glass
          ? Colors.transparent
          : colors.panel,
      child: Column(
        children: [
          if (widget.showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: FaTextField(
                key: const ValueKey('appsDirectorySearch'),
                controller: widget.controller.searchController,
                prefixIcon: const Icon(Icons.search, size: 17),
                hintText: context.l10n.launcherSearchHint,
              ),
            ),
          Expanded(
            child: AnimatedSwitcher(
              duration: FaMotion.duration(
                context,
                const Duration(milliseconds: 200),
              ),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              child: ListView(
                key: ValueKey(
                  'apps-directory-${widget.controller.section.name}-'
                  '${widget.runningApps.map((app) => app.id).join(',')}-'
                  '${widget.activeAppId}-$_installedCount',
                ),
                padding: EdgeInsets.only(top: widget.topPadding + 4, bottom: 4),
                children: [
                  _DirectoryRow(
                    key: const ValueKey('appsDirectoryMyApps'),
                    icon: Icons.apps_rounded,
                    title: context.l10n.appsMyApps,
                    subtitle: _installedCount == null
                        ? '…' // l10n:ignore
                        : context.l10n.appsInstalledCount(_installedCount!),
                    selected:
                        widget.controller.section ==
                        AppsDirectorySection.myApps,
                    onTap: () =>
                        widget.controller.select(AppsDirectorySection.myApps),
                  ),
                  _DirectoryRow(
                    key: const ValueKey('appsDirectoryStore'),
                    icon: Icons.download_rounded,
                    title: context.l10n.appsWidgetStore,
                    subtitle: context.l10n.appsWidgetCatalog,
                    selected:
                        widget.controller.section ==
                        AppsDirectorySection.widgetStore,
                    onTap: () => widget.controller.select(
                      AppsDirectorySection.widgetStore,
                    ),
                  ),
                  _DirectoryHeading(label: context.l10n.wideNavActivity),
                  _DirectoryRow(
                    key: const ValueKey('appsDirectoryRunning'),
                    icon: Icons.bolt_rounded,
                    live: widget.runningApps.isNotEmpty,
                    title: context.l10n.appsRunning,
                    subtitle: context.l10n.appsActiveCount(
                      widget.runningApps.length,
                    ),
                    selected: widget.activeAppId != null,
                    onTap: widget.runningApps.isEmpty
                        ? null
                        : () => widget.onOpenRunning(
                            widget.runningApps
                                    .where(
                                      (app) => app.id == widget.activeAppId,
                                    )
                                    .firstOrNull ??
                                widget.runningApps.last,
                          ),
                  ),
                  for (final app in widget.runningApps)
                    _RunningAppDirectoryEntry(
                      key: ValueKey('appsDirectoryRunningApp-${app.id}'),
                      app: app,
                      env: widget.env,
                      selected: app.id == widget.activeAppId,
                      onTap: () => widget.onOpenRunning(app),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _RunningAppDirectoryEntry extends StatelessWidget {
  const _RunningAppDirectoryEntry({
    super.key,
    required this.app,
    required this.env,
    required this.selected,
    required this.onTap,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 8, 2),
      child: Material(
        color: selected ? colors.panelAlt : Colors.transparent,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: colors.panelAlt,
          child: SizedBox(
            height: 46,
            child: Row(
              children: [
                AppIcon(app: app, env: env, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    app.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                Icon(
                  selected ? Icons.remove_rounded : Icons.bolt_rounded,
                  size: 15,
                  color: selected ? colors.indigo : colors.teal,
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Collapsed Apps keeps the two real destinations and every running app
/// visible instead of reducing the section to an empty strip.
final class CollapsedAppsDirectory extends StatelessWidget {
  const CollapsedAppsDirectory({
    super.key,
    required this.controller,
    required this.runningApps,
    required this.activeAppId,
    required this.env,
    required this.onOpenRunning,
  });

  final AppLauncherController controller;
  final List<JsAppInfo> runningApps;
  final String? activeAppId;
  final ExecutionEnv env;
  final ValueChanged<JsAppInfo> onOpenRunning;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        key: const ValueKey('collapsedAppsList'),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        children: [
          _CollapsedDirectoryButton(
            key: const ValueKey('collapsedAppsMyApps'),
            icon: Icons.apps_rounded,
            tooltip: context.l10n.appsMyApps,
            selected: controller.section == AppsDirectorySection.myApps,
            onTap: () => controller.select(AppsDirectorySection.myApps),
          ),
          _CollapsedDirectoryButton(
            key: const ValueKey('collapsedAppsStore'),
            icon: Icons.download_rounded,
            tooltip: context.l10n.appsWidgetStore,
            selected: controller.section == AppsDirectorySection.widgetStore,
            onTap: () => controller.select(AppsDirectorySection.widgetStore),
          ),
          if (runningApps.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final app in runningApps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: RunningAppIconButton(
                  key: ValueKey('collapsedRunningApp-${app.id}'),
                  app: app,
                  env: env,
                  selected: app.id == activeAppId,
                  onTap: () => onOpenRunning(app),
                  size: 54,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

final class _CollapsedDirectoryButton extends StatelessWidget {
  const _CollapsedDirectoryButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: selected
              ? colors.indigo.withValues(alpha: .22)
              : Colors.transparent,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              height: 54,
              child: Icon(
                icon,
                size: 25,
                color: selected ? colors.indigo : colors.dim,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DirectoryHeading extends StatelessWidget {
  const _DirectoryHeading({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => FaSectionEyebrow(label: label);
}

final class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.live = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  /// The running row's live accent (a teal dot over the glyph tile).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colors.panelAlt : Colors.transparent,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: colors.panelAlt,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.indigo.withValues(alpha: .16)
                        : colors.panelAlt.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 16,
                        color: selected ? colors.indigo : colors.dim,
                      ),
                      if (live)
                        Positioned(
                          top: 3,
                          right: 3,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: colors.teal,
                              shape: BoxShape.circle,
                              border: Border.fromBorderSide(
                                BorderSide(color: colors.panel, width: 1.5),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.dim, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
