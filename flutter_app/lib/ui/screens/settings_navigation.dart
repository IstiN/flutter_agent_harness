// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/ui/widgets/sidebar_nav_item.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The six stable top-level settings destinations. The concrete controls
/// live in the selected category's content pane, never in one long page.
enum SettingsCategory {
  providersModels,
  uiTheme,
  accountsSecrets,
  skillsTools,
  agentConfig,
  others,
}

/// Presentation metadata shared by the wide sidebar and narrow drill-down.
extension SettingsCategoryPresentation on SettingsCategory {
  /// The owner-specified category names intentionally stay in English.
  String get label => switch (this) {
    SettingsCategory.providersModels => 'Providers & Models', // l10n:ignore
    SettingsCategory.uiTheme => 'UI Theme', // l10n:ignore
    SettingsCategory.accountsSecrets => 'Accounts & Secrets', // l10n:ignore
    SettingsCategory.skillsTools => 'Skills & Tools', // l10n:ignore
    SettingsCategory.agentConfig => 'Agent Config', // l10n:ignore
    SettingsCategory.others => 'Others', // l10n:ignore
  };

  IconData get icon => switch (this) {
    SettingsCategory.providersModels => Icons.cloud_outlined,
    SettingsCategory.uiTheme => Icons.palette_outlined,
    SettingsCategory.accountsSecrets => Icons.key_outlined,
    SettingsCategory.skillsTools => Icons.handyman_outlined,
    SettingsCategory.agentConfig => Icons.tune_rounded,
    SettingsCategory.others => Icons.more_horiz_rounded,
  };
}

/// Settings' left navigation panel on wide layouts, or the category list
/// used by the narrow drill-down. It owns no settings controls itself.
class SettingsCategoryPanel extends StatelessWidget {
  const SettingsCategoryPanel({
    super.key,
    required this.selected,
    required this.onSelected,
    this.collapsed = false,
    this.showHeader = true,
    this.topPadding = 0,
    this.bottomReserve = 0,
  });

  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelected;
  final bool collapsed;
  final bool showHeader;

  /// Top inset supplied by a floating host header on narrow layouts.
  final double topPadding;

  /// Extra scroll padding under the floating phone dock — the narrow
  /// shell passes the dock's occupied height; desktop keeps 0 and the
  /// legacy 16pt inset.
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        8,
        topPadding + 4,
        8,
        16 + bottomReserve,
      ),
      children: [
        for (final category in SettingsCategory.values)
          SidebarNavItem(
            key: ValueKey('settingsCategory-${category.name}'),
            icon: category.icon,
            label: category.label,
            selected: selected == category,
            collapsed: collapsed,
            onTap: () {
              AppAnalytics.instance.screenOpened(
                'settings_category_${category.name}',
              );
              onSelected(category);
            },
          ),
      ],
    );
    return ColoredBox(
      key: const ValueKey('settingsCategoryPanel'),
      color: tokens.direction == FaVisualDirection.glass
          ? Colors.transparent
          : FahColors.of(context).panel,
      child: Column(
        children: [
          if (showHeader)
            SizedBox(
              height: 58,
              child: collapsed
                  ? null
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          context.l10n.settingsTitle,
                          style: FaTypography.of(context).title.copyWith(
                            color: tokens.ink1,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
            ),
          Expanded(child: list),
        ],
      ),
    );
  }
}
