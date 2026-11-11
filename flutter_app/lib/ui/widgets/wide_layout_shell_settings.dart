// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'wide_layout_shell.dart';

/// Settings navigation owned by the responsive messenger shell. Wide
/// layouts keep categories in the ordinary sidebar and replace only the
/// transcript; narrow layouts use a full-route category drill-down.
extension _WideLayoutShellSettings on _WideLayoutShellState {
  Widget _buildSettingsPanel({bool collapsed = false}) {
    // Narrow only: the floating dock scrolls over the category list, so its
    // occupied height is reserved as scroll padding. Desktop sidebars keep
    // the legacy geometry (no dock, raw MediaQuery insets).
    final dockReserve = _isNarrow
        ? MessengerFloatingDockInsets.bottomOf(context)
        : 0.0;
    return SettingsCategoryPanel(
      selected: _settingsCategory,
      collapsed: collapsed,
      bottomReserve: dockReserve,
      onSelected: (category) {
        _settingsCategory = category;
        _selectSection(_WideShellSection.settings);
      },
    );
  }

  Widget _buildSettingsArea() {
    return SettingsScreen(
      service: widget.manager.active?.service,
      env: widget.manager.env,
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
      layoutStore: widget.layoutStore,
      category: _settingsCategory,
      embedded: true,
      onBack: () => _selectSection(_WideShellSection.chats),
    );
  }

  Future<void> _openSettings() async {
    AppAnalytics.instance.settingsOpened();
    if (!mounted) return;
    final service = widget.manager.active?.service;
    if (_isNarrow) {
      // SettingsScreen owns its SafeArea. Wrapping the route in another
      // right inset would shrink every category twice on Duo.
      await pushFaPage<void>(
        context,
        SettingsScreen(
          service: service,
          env: widget.manager.env,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          layoutStore: widget.layoutStore,
          categorized: true,
        ),
      );
      return;
    }
    _selectSection(_WideShellSection.settings);
  }
}
