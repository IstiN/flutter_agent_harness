// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/apps/app_launcher_controller.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The desktop Apps directory from the messenger PoC: search, My Apps,
/// Widgets Catalog, and the real currently-running app panel.
final class AppsDirectoryPanel extends StatefulWidget {
  const AppsDirectoryPanel({
    super.key,
    required this.controller,
    required this.appsStore,
    required this.runningAppName,
    required this.onOpenRunning,
    this.showSearch = true,
  });

  final AppLauncherController controller;
  final AppsStore appsStore;
  final String? runningAppName;
  final VoidCallback onOpenRunning;
  final bool showSearch;

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
                  '${widget.runningAppName}-$_installedCount',
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _DirectoryHeading(label: context.l10n.appsGridTitle),
                  _DirectoryRow(
                    key: const ValueKey('appsDirectoryMyApps'),
                    symbol: 'A', // l10n:ignore
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
                    symbol: 'W', // l10n:ignore
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
                    symbol: '●', // l10n:ignore
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

final class _DirectoryHeading extends StatelessWidget {
  const _DirectoryHeading({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => FaSectionEyebrow(label: label);
}

final class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({
    super.key,
    required this.symbol,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String symbol;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    symbol,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.dim, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
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
