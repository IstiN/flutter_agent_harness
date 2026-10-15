/// The `/provider export` REPL flow (gh-1606): copies the saved Copilot
/// account's full token to the clipboard — no transcript output, no
/// flags, no reveal ceremony. Split from `provider_commands.dart` to keep
/// that file under the 2800-line gate.
part of 'agent_cli.dart';

extension on AgentCli {
  /// The `/provider export` branch: usage + dispatch into the gated flow.
  /// Returns true when the command targeted the export.
  bool _startProviderExportArg(List<String> args) {
    if (args.first != 'export') return false;
    if (args.length > 1) {
      io.writeln('usage: /provider export');
      return true;
    }
    unawaited(_handleProviderExportCommand());
    return true;
  }

  /// Runs the export with the shared flow gate (the picker needs the REPL
  /// answering lines, like the connect flow).
  Future<void> _handleProviderExportCommand() async {
    if (_providerFlowActive) return;
    _providerFlowActive = true;
    try {
      await _runProviderExportCommand();
    } finally {
      _providerFlowActive = false;
      _promptLineBuffer.clear();
    }
  }

  Future<void> _runProviderExportCommand() async {
    final registry = config.customProviders;
    final accounts = [
      for (final entry in registry?.entries ?? const <CustomProviderEntry>[])
        if (entry.apiType == 'copilot') entry,
    ];
    if (accounts.isEmpty) {
      io.writeln(
        'no saved Copilot account — connect one with /provider copilot',
      );
      return;
    }
    final entry = accounts.length == 1
        ? accounts.single
        : await _pickExportCopilotAccount(accounts);
    if (entry == null) {
      io.writeln('Copilot export cancelled');
      return;
    }
    final keyName = entry.keyName;
    final token = keyName == null ? null : config.secureKeys?.read(keyName);
    if (token == null || token.isEmpty) {
      io.writeln(
        'no stored token for ${entry.name} — reconnect with '
        '/provider copilot',
      );
      return;
    }
    final failure = await _copyToClipboard(token);
    if (failure == null) {
      io.writeln('token copied to clipboard');
    } else {
      io.writeln('could not copy the token to the clipboard: $failure');
    }
  }

  /// The multi-account picker of the export flow (the connect flow's
  /// account list minus the "add another account" row). Null = cancelled.
  Future<CustomProviderEntry?> _pickExportCopilotAccount(
    List<CustomProviderEntry> accounts,
  ) async {
    final choice = await _pickOption('Copilot account', [
      for (final entry in accounts)
        (entry.name, entry.name, '${entry.baseUrl} · ${entry.modelId}'),
    ]);
    if (choice == null) return null;
    return config.customProviders?.find(choice);
  }

  /// Copies [text] to the host clipboard. Resolves to null on success, the
  /// named failure reason otherwise (the text itself never surfaces).
  Future<String?> _copyToClipboard(String text) async {
    final injected = config.clipboardWrite;
    if (injected != null) return injected(text);
    final result = await writeClipboardText(text);
    return switch (result) {
      PasteboardWriteOk() => null,
      PasteboardWriteUnavailable(:final reason) => reason,
    };
  }
}
