/// The messaging fabric for agents: every agent (the main orchestrator,
/// retained subagents, and Fa instances sharing one messaging root) owns an
/// INBOX. Senders deposit messages; recipients drain them at their next turn
/// boundary.
///
/// The repository is an isolated interface on purpose: the file
/// implementation ([FileMessagingRepository]) is the default, but a future
/// database/network implementation only has to satisfy this contract — no
/// caller changes.
library;

import 'agent_message.dart';

/// Presence of a mailbox owner, as REPORTED by its transport — the hub
/// roster ([AgentInfo.online] analog) is authoritative for `live`/`offline`
/// (registration/connection, not mtime heuristics); the file fabric
/// reports `busy` from the instance's own marker and leaves the rest to
/// the activity heuristics above it.
enum AgentPresence {
  /// The owner is connected and accepting mail (hub: authenticated
  /// connection; file fabric: fresh heartbeat, implied — never written).
  live,

  /// An agent run is in progress; mail is still accepted (steering
  /// semantics — the loop drains the inbox between turns).
  busy,

  /// The owner is not connected (hub) / stopped heartbeating (file).
  offline,
}

/// One announced capability in the discovery surface (issue #27 phase 2):
/// a namespaced string (`yoclip.render`) plus an optional short
/// description and payload hint. Discovery metadata only — invocation
/// stays a plain DM; nothing here routes or invokes anything.
final class AgentCapability {
  /// Creates a capability; [name] is the namespaced id peers see in
  /// `agent_directory`, [description] and [payload] are optional
  /// human/model-readable hints.
  const AgentCapability({required this.name, this.description, this.payload});

  /// The namespaced capability id (e.g. `yoclip.render`).
  final String name;

  /// One-line description of what invoking the peer for this is good for.
  final String? description;

  /// Free-form payload hint (what to include in the DM), when any.
  final String? payload;

  /// Tolerant decode of the `.capabilities` marker payload: a JSON list of
  /// `{name, description?, payload?}` maps; malformed entries are skipped.
  static List<AgentCapability> listFromJson(Object? node) => [
    if (node is List)
      for (final entry in node)
        if (entry is Map &&
            entry['name'] is String &&
            (entry['name'] as String).isNotEmpty)
          AgentCapability(
            name: entry['name'] as String,
            description: entry['description'] is String
                ? entry['description'] as String
                : null,
            payload: entry['payload'] is String
                ? entry['payload'] as String
                : null,
          ),
  ];

  List<Map<String, String>> toJson() => [
    {'name': name, 'description': ?description, 'payload': ?payload},
  ];

  @override
  String toString() => 'AgentCapability($name)';

  @override
  bool operator ==(Object other) =>
      other is AgentCapability &&
      other.name == name &&
      other.description == description &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(name, description, payload);
}

/// One entry in the messaging-fabric directory.
class MailboxEntry {
  /// Creates a directory entry with optional session name, cwd, slug,
  /// presence, activity and capability metadata.
  const MailboxEntry({
    required this.id,
    this.name,
    this.cwd,
    this.slug,
    this.lastActivity,
    this.presence,
    this.capabilities = const [],
  });

  /// The mailbox id (e.g. `a1`, `sess1/main`).
  final String id;

  /// The session display name this mailbox belongs to, when known — the
  /// human-addressable form (`--session goal_builder`). Senders may use it
  /// wherever a mailbox id is expected: `goal_builder` or
  /// `goal_builder/main` resolve through the directory. Null for legacy
  /// mailboxes registered before names existed.
  final String? name;

  /// The working directory this mailbox belongs to, when known.
  final String? cwd;

  /// The session slug this mailbox belongs to, when known.
  final String? slug;

  /// The newest activity observed in this mailbox. SOURCE-DEFINED: the file
  /// repository reports the newest file mtime inside the mailbox (heartbeat
  /// marker, inbox and read content); a future hub-presence feed would
  /// report its own activity semantics — never compare values across
  /// sources. Null when the source cannot date the mailbox.
  final DateTime? lastActivity;

  /// The transport-REPORTED presence state, when the source knows it:
  /// the hub roster sets `live`/`offline` from registration (authoritative,
  /// not an mtime heuristic), the file fabric sets `busy` from the
  /// instance's marker. Null = derive from [lastActivity] heuristics.
  final AgentPresence? presence;

  /// Capabilities the owner announced at registration (`fabric.enable`
  /// analog). Empty for sources that do not carry them (the hub roster,
  /// legacy mailboxes).
  final List<AgentCapability> capabilities;

  /// How recent [lastActivity] must be for a mailbox to count as live in
  /// directory views. Generous enough that a briefly paused watcher never
  /// makes a running peer vanish.
  static const Duration defaultLiveWindow = Duration(minutes: 15);

  /// Whether [lastActivity] counts as live: inside [window] of [now]. An
  /// UNKNOWN timestamp (null) counts as live — a source that cannot date a
  /// mailbox must never have it hidden from the default view.
  static bool isLive(
    DateTime? lastActivity, {
    DateTime? now,
    Duration window = defaultLiveWindow,
  }) {
    if (lastActivity == null) return true;
    final reference = now ?? DateTime.now();
    return reference.difference(lastActivity) <= window;
  }

  @override
  String toString() =>
      'MailboxEntry($id, name: $name, cwd: $cwd, slug: $slug, '
      'presence: $presence, lastActivity: $lastActivity, '
      'capabilities: $capabilities)';

  @override
  bool operator ==(Object other) =>
      other is MailboxEntry &&
      other.id == id &&
      other.name == name &&
      other.cwd == cwd &&
      other.slug == slug &&
      other.lastActivity == lastActivity &&
      other.presence == presence &&
      _capabilitiesEquals(other.capabilities);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    cwd,
    slug,
    lastActivity,
    presence,
    Object.hashAll(capabilities),
  );

  /// Const-list equality: capabilities compare element-wise so const []
  /// from different sources still matches.
  bool _capabilitiesEquals(List<AgentCapability> other) {
    if (other.length != capabilities.length) return false;
    for (var i = 0; i < capabilities.length; i++) {
      if (capabilities[i] != other[i]) return false;
    }
    return true;
  }
}

/// Isolated messaging backend for agent inboxes.
abstract interface class MessagingRepository {
  /// Delivers [message] to the recipient's inbox. Implementations must
  /// assign/keep a unique [AgentMessage.id] and never lose a message
  /// silently (a failed delivery throws).
  Future<void> send(AgentMessage message);

  /// Announces [agentId]'s mailbox in the directory (presence): an agent
  /// with no mail yet is still discoverable. [sessionName], when non-empty,
  /// publishes the session's display name so peers can address this
  /// mailbox by name (`goal_builder` instead of `sess1/main`).
  /// [capabilities] publishes the host's discovery metadata
  /// (`fabric.enable(name, capabilities)` — see [AgentCapability]); an
  /// empty list clears any previously announced set. Called by hosts on
  /// session start/switch.
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  });

  /// Refreshes [agentId]'s liveness marker (a heartbeat): hosts call this
  /// periodically while the agent runs so directory consumers can tell live
  /// mailboxes from abandoned ones WITHOUT any pending mail. [busy] reports
  /// an agent run in progress (mail still accepted — steering semantics);
  /// a fresh `busy` beats the liveness heuristics in directory views.
  /// Best-effort by contract — a failing backend never breaks the caller's
  /// loop.
  Future<void> touch(String agentId, {bool busy = false});

  /// The unread messages for [agentId], oldest first, without consuming
  /// them.
  Future<List<AgentMessage>> peek(String agentId);

  /// The unread messages for [agentId], oldest first, consumed (marked
  /// read). A drained message never appears again.
  Future<List<AgentMessage>> drain(String agentId);

  /// The known mailboxes in the fabric, with optional cwd metadata. The
  /// FULL set (live and stale alike) — live/dead filtering is a display
  /// policy above this layer, not a repository concern.
  Future<List<MailboxEntry>> directory();
}
