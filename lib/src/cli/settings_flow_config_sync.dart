/// The settings-hub user-config re-sync hook of [AgentCli] (gh-1572
/// rework). Split out of `settings_flow.dart` for the repo's 2800-line
/// size gate — same library (a `part of`), so the extension sees the
/// class's private members.
part of 'agent_cli.dart';

extension SettingsConfigSyncFlow on AgentCli {
  /// Fires [AgentCliConfig.onUserConfigFileChanged] — a sanctioned direct
  /// write to the USER config file just landed (a surgical upsert, a
  /// drop-key or clear-key edit), and the executable holds a boot-time
  /// snapshot of that file that its whole-file saves copy from. Without
  /// the re-sync the next `persistConfig()` re-rendered the stale boot
  /// values OVER the flow's write: a cleared context cap resurrected, an
  /// `auto_update: false` re-added, a global compaction pick overwritten
  /// (gh-1572 rework). Awaited, so the freshest on-disk truth is what the
  /// next save sees. No-op on hosts without the hook (tests, web).
  Future<void> _notifyUserConfigFileChanged() async {
    final hook = config.onUserConfigFileChanged;
    if (hook != null) await hook();
  }
}
