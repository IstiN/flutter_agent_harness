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
    await _reloadUserThemes();
    final resolved = name == 'reset' ? kDefaultTuiTheme.name : name;
    await _applyThemeChoice(resolved, persist: true);
  }

  /// Opens the theme picker with live swatch previews; the current theme is
  /// preselected AND text-marked (`✓ current`, gh-671 — the swatch stays on
  /// every row, the marker is readable text in every palette).
  void _openThemePicker() {
    final controller = FaThemeController.instance;
    _tuiController?.openPicker(
      'theme',
      'Select theme',
      themePickerItems(current: controller.currentName),
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

  /// Test seam: runs the async half of the boot theme application — the
  /// constructor fires [_applyBootTheme] unawaited; tests await this.
  @visibleForTesting
  Future<void> bootThemeForTest() => _applyBootTheme();

  /// Applies the persisted `tui.theme` at boot: user themes load first so
  /// a persisted user theme resolves end to end (AC4). No persist
  /// round-trip.
  Future<void> _applyBootTheme() async {
    await _reloadUserThemes();
    final persisted = config.tuiTheme;
    if (persisted == null || persisted.isEmpty) return;
    if (!FaThemeController.instance.switchTo(persisted)) {
      io.writeln(
        'config tui.theme: unknown theme "$persisted" — using default '
            '(available: ${FaThemeController.instance.available().keys.join(', ')})',
      );
    }
  }

  /// (Re)loads `~/.fah/themes/*.json` into the controller — at boot and
  /// before every `/theme` resolution, so a theme the agent just wrote
  /// resolves without a restart (AC5). Shadowing names and unparseable
  /// files surface as warnings, never a boot failure.
  Future<void> _reloadUserThemes() async {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return;
    final dir = '$home/.fah/themes';
    final listed = await _env.listDir(dir);
    final names = (listed.valueOrNull ?? const [])
        .map((entry) => entry.name)
        .where((name) => name.endsWith('.json'))
        .toList()
      ..sort();
    // Pre-read through the FileSystem seam (web-safe); unreadable files
    // drop out here instead of parsing as garbage.
    final readable = <String, String>{};
    for (final name in names) {
      final path = '$dir/$name';
      final text = (await _env.readTextFile(path)).valueOrNull;
      if (text != null) readable[path] = text;
    }
    final loaded = loadUserThemes(
      home,
      (_) => readable.keys.toList(),
      (path) => readable[path] ?? '',
    );
    FaThemeController.instance.addUserThemes(loaded.themes);
    for (final error in loaded.errors) {
      io.writeln(error);
    }
  }
}
