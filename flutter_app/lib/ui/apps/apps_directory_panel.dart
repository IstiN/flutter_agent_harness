// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/apps/app_launcher_controller.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The desktop Apps directory from the messenger PoC: a glass capsule
/// toolbar (the sidebar chrome language), then My Apps, Widgets Catalog,
/// and the real currently-running app row.
final class AppsDirectoryPanel extends StatefulWidget {
  const AppsDirectoryPanel({
    super.key,
    required this.controller,
    required this.appsStore,
    required this.runningAppName,
    required this.onOpenRunning,
    this.showSearch = true,
    this.onOpenFiles,
  });

  final AppLauncherController controller;
  final AppsStore appsStore;
  final String? runningAppName;
  final VoidCallback onOpenRunning;
  final bool showSearch;

  /// Opens Files through the same presented-in-right-pane flow as JS
  /// apps. Null (hosts without the presentation shell) hides the action.
  final VoidCallback? onOpenFiles;

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
          _DirectoryToolbar(
            running: widget.runningAppName != null,
            onOpenFiles: widget.onOpenFiles,
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
                  '${widget.runningAppName}-$_installedCount',
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
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
                    live: widget.runningAppName != null,
                    title: context.l10n.appsRunning,
                    subtitle:
                        widget.runningAppName ??
                        context.l10n.appsActiveCount(0),
                    selected: widget.runningAppName != null,
                    onTap: widget.runningAppName == null
                        ? null
                        : widget.onOpenRunning,
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

/// The directory's capsule toolbar: a styleguide glass capsule carrying
/// the section label and the Files entry — Files opens through the same
/// presented-in-right-pane flow as JS apps, so it lives beside them.
final class _DirectoryToolbar extends StatelessWidget {
  const _DirectoryToolbar({required this.running, this.onOpenFiles});

  final bool running;
  final VoidCallback? onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: FaSurface(
        key: const ValueKey('appsDirectoryToolbar'),
        glass: true,
        useBackdropGroup: true,
        color: tokens.surface1,
        tintAmount: .22,
        tintOpacity: .55,
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: 34,
          child: Row(
            children: [
              Icon(Icons.grid_view_rounded, size: 15, color: colors.dim),
              const SizedBox(width: 8),
              Expanded(
                child: FaSectionEyebrow(
                  label: context.l10n.appsGridTitle,
                  padding: EdgeInsets.zero,
                ),
              ),
              if (running) ...[
                const SizedBox(width: 6),
                Container(
                  key: const ValueKey('appsDirectoryRunningDot'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: colors.teal,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              if (onOpenFiles != null) ...[
                const SizedBox(width: 4),
                SizedBox(
                  key: const ValueKey('appsDirectoryFiles'),
                  child: FaIconButton(
                    icon: Icons.folder_open_outlined,
                    tooltip: context.l10n.filesPanelTitle,
                    onPressed: onOpenFiles,
                  ),
                ),
              ],
            ],
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
