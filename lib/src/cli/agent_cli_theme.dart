// `/theme` — runtime theme switching (issue #279). Split from
// agent_cli_commands.dart to keep files under the 2800-line gate: the
// listing/picker, the switch + persist flow, and the boot-time apply.
part of 'agent_cli.dart';

/// Theme management on [AgentCli] (issue #279).
extension ThemeCommands on AgentCli {
  /// The `/theme` arm: bare opens the picker (TUI) or prints the table
  /// (line mode); `<name>` switches + persists `tui.theme`; `reset` returns
  /// to the default. Unknown names are a named error listing what exists.
  Future<void> _themeSlash(String rest) async {
    final name = rest.trim();
    if (name.isEmpty) {
      if (_useTui && _tuiController != null) {
        _openThemePicker();
      } else {
        for (final line in themeTableLines(
          current: FaThemeController.instance.currentName,
        )) {
          io.writeln(line);
        }
      }
      return;
    }
    final resolved = name == 'reset' ? kDefaultTuiTheme.name : name;
    await _applyThemeChoice(resolved, persist: true);
  }

  /// Opens the theme picker with live swatch previews; the current theme is
  /// preselected.
  void _openThemePicker() {
    final controller = FaThemeController.instance;
    final items = [
      for (final entry in controller.available().entries)
        MenuItem(
          key: entry.key,
          label: entry.key,
          description: entry.key == controller.currentName
              ? '(current)'
              : themeSwatchRow(entry.value),
        ),
    ];
    _tuiController?.openPicker(
      'theme',
      'Select theme',
      items,
      initialKey: controller.currentName,
    );
  }

  /// Switches the session theme to [name] and (optionally) persists it to
  /// `tui.theme`; confirms with the swatch line. The TUI repaints on the
  /// next frame boundary (E1 — never a torn frame).
  Future<void> _applyThemeChoice(String name, {required bool persist}) async {
    final controller = FaThemeController.instance;
    if (!controller.switchTo(name)) {
      io.writeln(
        'unknown theme: $name — available: '
            '${controller.available().keys.join(', ')}',
      );
      return;
    }
    _tuiController?.sendThemeChanged();
    if (persist) {
      try {
        final result = await ConfigService(
          env: _env,
          homeDir: config.homeDir,
        ).set('tui.theme', controller.currentName);
        io.writeln(
          'theme: ${controller.currentName} '
              '${themeSwatchRow(controller.current)}'
              ' — saved to ${result.file} (tui.theme)',
        );
      } on ConfigException catch (error) {
        io.writeln('theme switched, but saving tui.theme failed: $error');
      }
    } else {
      io.writeln(
        'theme: ${controller.currentName} '
            '${themeSwatchRow(controller.current)}',
      );
    }
  }

  /// Applies the persisted `tui.theme` at boot (no persist round-trip).
  void _applyBootTheme() {
    final persisted = config.tuiTheme;
    if (persisted == null || persisted.isEmpty) return;
    if (!FaThemeController.instance.switchTo(persisted)) {
      io.writeln(
        'config tui.theme: unknown theme "$persisted" — using default '
            '(available: ${FaThemeController.instance.available().keys.join(', ')})',
      );
    }
  }
}
