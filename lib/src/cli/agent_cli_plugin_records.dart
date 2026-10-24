part of 'agent_cli.dart';

// Host session-record seam for plugins (issue #1825) and the composer
// DAP-invite shortcut (AC7). Split out of `agent_cli.dart` to keep it
// under the repo's line gate; the extension sees private members.
extension AgentCliPluginRecords on AgentCli {
  /// Publishes session readiness after boot/resume or an in-process reset.
  /// Listeners are synchronous invalidation hooks; async work stays in the
  /// plugin's inbox/probe paths so it cannot delay session startup.
  void _notifyPluginSessionReady() {
    for (final listener in _pluginSessionReadyListeners) {
      listener();
    }
  }

  /// Backs [PluginContext.appendSessionRecord]: persists a plugin's
  /// session-scoped state as a custom record on the session JSONL tree.
  /// Lazy [_session] lookup — plugins register in the constructor, the
  /// session arrives later.
  Future<void> _appendPluginSessionRecord(
    String customType,
    Map<String, Object?> data,
  ) async {
    final session = _session;
    if (session == null) return;
    await session.appendCustomEntry(customType: customType, data: data);
  }

  /// Backs [PluginContext.readSessionRecords]: the current branch's
  /// records of [customType], oldest first — so session-scoped state
  /// follows the branch it was recorded on (E5).
  Future<List<Map<String, Object?>>> _readPluginSessionRecords(
    String customType,
  ) async {
    final session = _session;
    if (session == null) return const [];
    final branch = await session.getBranch();
    return [
      for (final record in branch)
        if (record is CustomRecord &&
            record.customType == customType &&
            record.data is Map)
          (record.data! as Map).cast<String, Object?>(),
    ];
  }

  /// Conservative invite detector for the composer shortcut (AC7): only
  /// UNAMBIGUOUS invite forms intercept — a full `ws(s)://…?channel=`
  /// invite or a pasted `fa dap import …` command. A bare channel id (or
  /// any other prose) never does: the word "team" must stay a message.
  bool _looksLikeDapInvite(String trimmed) {
    if (trimmed.startsWith('fa dap import ')) return true;
    if (!trimmed.startsWith('wss://') && !trimmed.startsWith('ws://')) {
      return false;
    }
    return trimmed.contains('channel=') && !trimmed.contains(RegExp(r'\s'));
  }

  /// AC7: a pasted DAP invite opens the SAME `/network` join wizard
  /// (prefilled) instead of becoming an agent message. Returns false
  /// when the input is not an invite or no `/network` handler is
  /// registered (hub plugin off) — the normal message path then applies.
  Future<bool> _tryDapInviteIntercept(String trimmed) async {
    if (!_looksLikeDapInvite(trimmed)) return false;
    final network = _pluginSlashCommands['/network'];
    if (network == null) return false;
    await network(['join', trimmed]);
    return true;
  }
}
