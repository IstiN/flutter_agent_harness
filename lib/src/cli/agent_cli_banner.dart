/// The startup banner (`_printBanner`) plus a thin delegate over the pure
/// [KeyStatusRenderer] (`_keyStatusLine`) and the media-key resolver
/// (`_resolveMediaKey`). Split out of `agent_cli.dart` to keep that file
/// under the repo's 2800-line size gate. Same library (a `part of`), so the
/// extension sees the class's private members.
part of 'agent_cli.dart';

/// Banner + key-status members of [AgentCli].
extension on AgentCli {
  Future<void> _printBanner() async {
    final model = _agent.state.model;
    final metadata = await _session!.getMetadata();
    io.writeln(
      '${tuiFaMark()}'
      '${_style.dim('v$_version')}',
    );
    io.writeln(
      _style.dim('escape interrupt · ctrl+c clear/exit · / commands · ! bash'),
    );
    io.writeln(_style.dim('Press /help to show full commands and resources.'));
    io.writeln('');
    io.writeln(_style.bold('[Context]'));
    io.writeln('  ${_env.cwd}');
    io.writeln('');
    io.writeln(_style.bold('[Model]'));
    io.writeln('  ${model.id} (${model.api})');
    io.writeln('  endpoint: ${model.baseUrl}');
    final keyStatus = _keyStatusLine(model);
    if (keyStatus != null) {
      io.writeln(
        keyStatus.startsWith('key: no key set')
            ? '  ${tuiWarning(keyStatus)}'
            : '  $keyStatus',
      );
    }
    io.writeln('');
    io.writeln(_style.bold('[Session]'));
    final sessionName = await _session?.getSessionName();
    if (sessionName != null && sessionName.isNotEmpty) {
      io.writeln('  $sessionName');
    }
    io.writeln('  ${metadata.path}');
    // pi benchmark mode (issue #679, experimental design): the boot
    // prints the initial-context size so cross-mode runs are comparable —
    // the same chars/4 estimator pi uses (`token_estimation.dart`, ported
    // from pi-mono) over the composed system prompt plus any restored
    // messages. Default mode prints nothing (REG byte-parity).
    if (config.agentMode == 'pi') {
      final initialTokens =
          _agent.state.systemPrompt.length ~/ 4 +
          _agent.state.messages.fold<int>(
            0,
            (total, message) => total + estimateTokens(message),
          );
      io.writeln(
        '  pi benchmark: initial context ~$initialTokens tokens '
        '(chars/4 est.)',
      );
    }
  }

  /// The banner's key-status line — delegates to [_keyStatusView] (see
  /// [KeyStatusRenderer.keyStatusLine]).
  String? _keyStatusLine(Model model) => _keyStatusView.keyStatusLine(model);

  /// Resolves a named secret (env first, then the secure store) for media
  /// slot `apiKeyName` overrides. Returns null when the name is unknown.
  Future<String?> _resolveMediaKey(String name) async {
    final value = config.envVarValue?.call(name);
    if (value != null && value.isNotEmpty) return value;
    return config.secureKeys?.read(name);
  }
}
