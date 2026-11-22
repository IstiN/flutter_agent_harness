part of 'agent_cli.dart';

/// Best-effort device-network presence: an unavailable relay must never
/// block or fail a local coding session. No exception text is printed here
/// because transport errors may contain the single-use-ticket dial URL.
Future<void> _startNetworkPresenceFor(AgentCli cli) async {
  final presence = cli.config.networkPresence;
  final session = cli._session;
  final sessionId = session?.cachedId;
  if (presence == null || sessionId == null || sessionId.isEmpty) return;
  final manager = cli._subagentManager;
  if (presence case final CliNetworkSessionWakeTarget wakeTarget) {
    wakeTarget.wakeLauncher = cli._launchMailboxWake;
  }
  final mailbox = manager.mailboxOf(manager.selfId);
  manager.networkDmGateway = (address, message) =>
      _sendNetworkDmReply(cli, address: address, text: message.text);
  try {
    await presence.startSession(
      CliNetworkSession(
        sessionId: sessionId,
        mailboxPrefix: manager.mailboxPrefix,
        dmSink: (dm) => _deliverNetworkDm(cli, dm, mailbox: mailbox),
        onNotice: (message) =>
            cli.io.writeln(cli._style.dim('[network] $message')),
        // Friendly title/cwd ride the live presence overlay even before
        // the persisted catalog rediscovers this session (owner: named
        // session rendered as `CLI · <uuid>` on the app's device page).
        displayName: await session?.getSessionName(),
        cwd: cli._env.cwd,
      ),
    );
  } on Object {
    cli._logDiagnostic('network presence unavailable (start failed)');
  }
}

/// Writes one authenticated network DM into the SAME mailbox drained by the
/// existing externalSteeringSource/idle-wake path. No agent invocation or new
/// wake loop belongs here: kind:user mail already resets the inbox policy and
/// the regular watcher supplies both mid-run steering and idle wake.
Future<void> _deliverNetworkDm(
  AgentCli cli,
  CliNetworkDm dm, {
  required String mailbox,
}) async {
  final manager = cli._subagentManager;
  final messaging = manager.messaging;
  if (messaging == null) {
    throw StateError('network DM mailbox is unavailable');
  }
  // Keep the durable route in the fabric message for restart safety, but
  // give the model a short directory alias instead of a multi-line token.
  manager.registerNetworkDmPeer(name: dm.senderLabel, address: dm.replyAddress);
  final mail = dm.mail;
  await messaging.send(
    AgentMessage(
      id: networkDmMailboxMessageId(mail.envelope),
      fromId: dm.replyAddress,
      toId: mailbox,
      text: mail.text,
      sentAt: mail.envelope.ts,
      hops: 0,
      kind: AgentMessageKind.user,
      fromName: 'network DM · ${dm.senderLabel}',
    ),
  );
}

Future<void> _sendNetworkDmReply(
  AgentCli cli, {
  required String address,
  required String text,
}) async {
  final sender = cli.config.networkPresence;
  if (sender is! CliNetworkDmReplySender) {
    throw StateError(
      'network DM replies are unavailable: this CLI has no device DM gateway',
    );
  }
  try {
    await (sender as CliNetworkDmReplySender).sendNetworkDmReply(
      address: address,
      text: text,
    );
  } on FormatException catch (error) {
    throw StateError(error.message);
  }
}

Future<void> _stopNetworkPresenceFor(AgentCli cli) async {
  try {
    await cli.config.networkPresence?.stop();
  } on Object {
    cli._logDiagnostic('network presence unavailable (stop failed)');
  } finally {
    cli._subagentManager.networkDmGateway = null;
  }
}

void _updateNetworkPresenceBusyFor(AgentCli cli) {
  try {
    cli.config.networkPresence?.setBusy(cli.isBusy);
  } on Object {
    // A telemetry row is never allowed to break the heartbeat.
  }
}
