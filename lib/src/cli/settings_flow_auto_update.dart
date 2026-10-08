/// The settings-hub Auto update flow of [AgentCli] (issue #1377): the
/// notify → on → off policy toggle. Split out of `settings_flow.dart`
/// for the repo's 2800-line size gate — same library (a `part of`), so
/// the extension sees the class's private members and the shared config
/// helpers.
part of 'agent_cli.dart';

extension SettingsAutoUpdateFlow on AgentCli {
  /// Settings → Auto update (issue #1377): one pick cycles the policy
  /// notify → on → off and persists to the GLOBAL config file through the
  /// surgical upsert, validated with the real parser before the write.
  /// The notify default is never written — cycling back onto it drops the
  /// key instead.
  Future<void> startAutoUpdateFlow() async {
    final next = switch (config.autoUpdate) {
      AutoUpdateMode.notify => AutoUpdateMode.on,
      AutoUpdateMode.on => AutoUpdateMode.off,
      AutoUpdateMode.off => AutoUpdateMode.notify,
    };
    final wrote = next == AutoUpdateMode.notify
        ? await _dropAutoUpdateKey()
        : await _writeAutoUpdateYaml(next);
    if (wrote) config.autoUpdate = next;
  }

  /// The settings-hub row and `/settings` summary label for the policy.
  String _autoUpdateStatusLabel() => config.autoUpdate.name;

  /// The confirm/write step: the surgical `auto_update` upsert, validated
  /// with the real parser before the file is written.
  Future<bool> _writeAutoUpdateYaml(AutoUpdateMode mode) =>
      _upsertConfigYaml(
        const ['auto_update'],
        mode.yamlValue,
        projectScope: false,
        validate: autoUpdateModeFromYaml,
      );

  /// The notify-default step: the key line is removed (defaults are never
  /// written), everything else survives byte-for-byte.
  Future<bool> _dropAutoUpdateKey() async {
    final path = _userConfigPath();
    if (path == null) {
      io.writeln('auto update: no user config on this host — not saved');
      return false;
    }
    final read = await _env.readTextFile(path);
    final String source;
    switch (read) {
      case Ok(:final value):
        source = value;
      case Err(:final error):
        io.writeln('cannot read $path: $error — not saved');
        return false;
    }
    final edited = _dropTopLevelBlock(source, 'auto_update');
    // Never persist a file the next boot would reject.
    try {
      loadYaml(edited);
    } on Object catch (error) {
      io.writeln('not saved: $error');
      return false;
    }
    if (await _env.writeFile(path, edited) is Err) {
      io.writeln('could not write $path');
      return false;
    }
    io.writeln('auto_update removed → $path (notify is the default)');
    return true;
  }
}
