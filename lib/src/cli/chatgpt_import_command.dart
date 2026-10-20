/// The `/provider chatgpt import [path]` flow (issue #1704): adopts a
/// `codex login` session file into the same secure-store slot the OAuth
/// flow writes. Split from `provider_commands.dart` to keep that file
/// under the 2800-line gate. Same library (a `part of`), so the extension
/// sees the class's private members.
part of 'agent_cli.dart';

extension ChatGptImportCommand on AgentCli {
  /// `/provider chatgpt import [path]`: reads a `codex login` session file
  /// (default `~/.codex/auth.json`) and applies it through the SAME
  /// storage/registry/switch path the OAuth flow uses — the imported blob
  /// lands in the entry's own secure-store slot and the session switches
  /// to the Codex backend at once (issue #1704).
  Future<void> _handleChatGptImportCommand(String? pathOption) async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      final home = config.homeDir ?? config.env.cwd;
      final path = _expandHomePath(
        pathOption ?? '$home/.codex/auth.json',
        home,
      );
      final String body;
      switch (await config.env.readTextFile(path)) {
        case Ok(:final value):
          body = value;
        case Err(:final error) when error.code == FileErrorCode.notFound:
          io.writeln(
            'codex CLI session not found at $path — run `codex login` '
            'first (or pass the path: /provider chatgpt import <path>)',
          );
          return;
        case Err(:final error):
          io.writeln('cannot read $path: $error');
          return;
      }
      final credentials = parseCodexAuthJson(body);
      if (credentials == null) {
        io.writeln(
          '$path is not a codex auth.json session (expected '
          '{"tokens": {access_token, refresh_token, id_token, ...}})',
        );
        return;
      }
      io.writeln('imported codex CLI session from $path');
      await _applyChatGptOAuthCredentials(
        providerCatalog['chatgpt']!,
        credentials,
      );
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  /// Expands a leading `~` to [home] (the import path operand).
  String _expandHomePath(String path, String home) {
    if (path == '~') return home;
    if (path.startsWith('~/')) return '$home${path.substring(1)}';
    return path;
  }
}
