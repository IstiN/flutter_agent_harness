part of 'agent_cli.dart';

/// Best-effort device-network presence: an unavailable relay must never
/// block or fail a local coding session. No exception text is printed here
/// because transport errors may contain the single-use-ticket dial URL.
Future<void> _startNetworkPresenceFor(AgentCli cli) async {
  final presence = cli.config.networkPresence;
  final session = cli._session;
  final sessionId = session?.cachedId;
  if (presence == null || sessionId == null || sessionId.isEmpty) return;
  try {
    await presence.startSession(
      CliNetworkSession(
        sessionId: sessionId,
        mailboxPrefix: cli._subagentManager.mailboxPrefix,
      ),
    );
  } on Object {
    cli._logDiagnostic('network presence unavailable (start failed)');
  }
}

Future<void> _stopNetworkPresenceFor(AgentCli cli) async {
  try {
    await cli.config.networkPresence?.stop();
  } on Object {
    cli._logDiagnostic('network presence unavailable (stop failed)');
  }
}

void _updateNetworkPresenceBusyFor(AgentCli cli) {
  try {
    cli.config.networkPresence?.setBusy(cli.isBusy);
  } on Object {
    // A telemetry row is never allowed to break the heartbeat.
  }
}
