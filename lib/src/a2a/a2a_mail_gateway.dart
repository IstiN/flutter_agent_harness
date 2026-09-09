/// The A2A boundary gateway (issue #27 phase 3): cross-machine fabric mail
/// rides A2A `message/send` as a `faMail` metadata envelope, and a serving
/// harness deposits inbound envelopes into its local fabric — the hub stays
/// the intra-machine transport, A2A stays the interop boundary.
///
/// Outbound: `agent_message to: "goal_builder@renderbox"` resolves the
/// machine against the `a2a:` config section (the server named `renderbox`)
/// and sends the mail with the envelope in the message metadata; a failed
/// remote task surfaces as an error, never a dead drop.
///
/// Inbound: `fa serve --a2a` mounts a mail sink; envelopes are delivered to
/// the local file inbox of the addressed session (by display name or
/// mailbox id) instead of running an agent turn.
library;

import '../messaging/agent_message.dart';
import '../messaging/messaging_repository.dart';
import 'a2a_client.dart';
import 'a2a_manager.dart';

/// The message-metadata key that marks an A2A `message/send` as fabric
/// mail. Its value is [A2aMailEnvelope]'s JSON.
const faMailMetadataKey = 'faMail';

/// Processes envelopes deposited by a remote sender. Returns the ack text
/// that becomes the A2A task artifact; a throw fails the task.
typedef A2aMailSink = Future<String> Function(A2aMailEnvelope envelope);

/// One fabric-mail envelope over the A2A wire.
final class A2aMailEnvelope {
  const A2aMailEnvelope({
    required this.id,
    required this.from,
    required this.to,
    required this.text,
    required this.sentAt,
    this.hops = 0,
  });

  /// The fabric message id (kept stable across the boundary so
  /// at-least-once redelivery can be deduped by id).
  final String id;

  /// The sender's reply address: `<mailbox>@<machine>` when the sender
  /// knows its own machine name, the bare mailbox otherwise.
  final String from;

  /// The recipient mailbox on the receiving machine: a session display
  /// name, an absolute mailbox id, or a `name/main` form.
  final String to;

  /// The message body.
  final String text;

  /// ISO 8601 send timestamp (UTC).
  final String sentAt;

  /// Remaining relay budget, carried verbatim.
  final int hops;

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    'to': to,
    'text': text,
    'sentAt': sentAt,
    'hops': hops,
  };

  /// The metadata map to attach to an A2A `message/send`.
  Map<String, dynamic> toMetadata() => {faMailMetadataKey: toJson()};

  /// Tolerant decode from message metadata: null unless the marker is
  /// present and the required fields are non-empty strings.
  static A2aMailEnvelope? fromMetadata(Map<String, dynamic>? metadata) {
    final node = metadata?[faMailMetadataKey];
    if (node is! Map) return null;
    String field(String key) => node[key]?.toString() ?? '';
    final to = field('to');
    final text = field('text');
    if (to.isEmpty || text.isEmpty) return null;
    return A2aMailEnvelope(
      id: field('id'),
      from: field('from'),
      to: to,
      text: text,
      sentAt: field('sentAt'),
      hops: int.tryParse(field('hops')) ?? 0,
    );
  }
}

/// Splits a `name@machine` remote address at the `@`. Both halves must be
/// non-empty; throws [StateError] otherwise.
(String, String) parseRemoteAddress(String address) {
  final at = address.indexOf('@');
  final name = at < 0 ? '' : address.substring(0, at).trim();
  final machine = at < 0 ? '' : address.substring(at + 1).trim();
  if (name.isEmpty || machine.isEmpty) {
    throw StateError(
      'invalid remote address "$address" — expected name@machine',
    );
  }
  return (name, machine);
}

/// Delivers fabric mail across machines through the configured A2A servers.
class A2aMailGateway {
  const A2aMailGateway({required this.manager, this.machineName});

  /// The session-scoped A2A manager (the `a2a:` config section).
  final A2aManager manager;

  /// This host's machine name; when known, outbound envelopes stamp it onto
  /// the sender address so the recipient can reply across the boundary.
  final String? machineName;

  /// Delivers [message] (addressed `name@machine`) to the remote machine.
  /// Throws [StateError] for a malformed address, an unconfigured machine
  /// (with the config hint), or a failed remote task ([A2aException] with
  /// the remote error text) — never a silent dead drop.
  Future<void> deliver(AgentMessage message) async {
    final (name, machine) = parseRemoteAddress(message.toId);
    final server = _serverForMachine(machine);
    if (server == null) {
      throw StateError(
        'no a2a server for machine "$machine" — add an '
        'a2a.servers.$machine entry (url) to ~/.fah/config.yaml',
      );
    }
    final stamp = machineName?.trim();
    final envelope = A2aMailEnvelope(
      id: message.id,
      from: stamp == null || stamp.isEmpty
          ? message.fromId
          : '${message.fromId}@$stamp',
      to: name,
      text: message.text,
      sentAt: message.sentAt,
      hops: message.hops,
    );
    final client = await manager.connect(server.config.name);
    final task = await client.sendMessage(
      message.text,
      metadata: envelope.toMetadata(),
    );
    if (task.state == A2aTaskState.failed) {
      throw A2aException(_remoteError(task));
    }
  }

  /// Deposits [envelope] into the local fabric: resolves the addressed
  /// mailbox (exact id, session display name, or `name/main`) and sends.
  /// Returns the ack for the A2A task artifact; throws [StateError] when
  /// no local mailbox matches.
  static Future<String> accept(
    A2aMailEnvelope envelope, {
    required MessagingRepository fabric,
  }) async {
    final target = await _resolveMailbox(fabric, envelope.to);
    await fabric.send(
      AgentMessage(
        id: envelope.id.isEmpty ? newMessageId() : envelope.id,
        fromId: envelope.from,
        toId: target,
        text: envelope.text,
        sentAt: envelope.sentAt,
        hops: envelope.hops,
      ),
    );
    return 'delivered to $target inbox';
  }

  /// Case-insensitive machine lookup over the configured servers.
  A2aManagedServer? _serverForMachine(String machine) {
    final needle = machine.toLowerCase();
    for (final server in manager.servers.values) {
      if (server.config.name.toLowerCase() == needle) return server;
    }
    return null;
  }

  /// The remote failure text: the last agent message, or a fallback.
  static String _remoteError(A2aTask task) {
    for (final message in task.messages.reversed) {
      if (message.role == 'agent' && message.textContent.isNotEmpty) {
        return message.textContent;
      }
    }
    return 'remote task ${task.id} failed';
  }

  /// Resolves a local mailbox: exact id first, then the session display
  /// name (a `name/main` form must match the name AND the id suffix).
  /// Ambiguous names list the candidates instead of guessing.
  static Future<String> _resolveMailbox(
    MessagingRepository fabric,
    String to,
  ) async {
    final entries = await fabric.directory();
    if (entries.any((entry) => entry.id == to)) return to;
    final slash = to.indexOf('/');
    final matches = slash < 0
        ? entries.where((entry) => entry.name != null && entry.name == to)
        : entries.where(
            (entry) =>
                entry.id.endsWith(to.substring(slash)) &&
                entry.name == to.substring(0, slash),
          );
    if (matches.length > 1) {
      throw StateError(
        'mailbox name "$to" is ambiguous on this machine — '
        'candidates: ${matches.map((e) => e.id).join(', ')}',
      );
    }
    if (matches.isEmpty) {
      throw StateError('unknown mailbox "$to" on this machine');
    }
    return matches.single.id;
  }
}
