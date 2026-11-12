/// Local device registry of agents and sessions with their network exposure
/// flags (contract `docs/fa_network_connector.md` §2/§6, amendment v1.1 §2).
///
/// Exposure truth lives HERE, on the device — the backend mirrors what this
/// registry publishes in roster/presence frames, never the other way round
/// (§6: "Exposure flags live locally (device registry)"). Defaults follow the
/// owner decision §0.2 / §2:
/// - **personal** network: agents ON, sessions ON (opt-out);
/// - **shared** network: deny-by-default — agents are visible only through
///   their channel membership in that network, sessions OFF until exposed;
/// - **unknown** network kind: treated as shared (conservative default).
///
/// Agent identity is a composite `(name, deviceId)` — the address form
/// `<agentName>@<deviceId>` (§1). DM key material (`dmPub`, consumed by a
/// later slice) is keyed by that full address, never the bare agent name.
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:async';

import 'envelope.dart';

/// The membership kind of a network, configured by the host at enroll
/// (contract §2: the backend auto-provisions ONE personal network per user;
/// shared networks join by the existing flow).
enum NetworkKind {
  /// The owner's personal network: exposure opt-out (§0.2).
  personal,

  /// A shared network: exposure deny-by-default (§0.2 amendment).
  shared,
}

/// One registered agent: the composite identity (§1) plus its DM public key
/// and per-network channel memberships. [dmPub] rides the roster entry
/// (§7); channel memberships drive shared-network visibility (§6).
final class AgentRegistration {
  /// Registers agent [name] on device [deviceId]. [dmPub] is the agent's
  /// base64 x25519 DM public key when one is provisioned; [memberships]
  /// maps networkId → the channel ids the agent is a member of there.
  AgentRegistration({
    required this.name,
    required this.deviceId,
    this.dmPub,
    Map<String, Set<String>> memberships = const {},
  }) : memberships = Map.unmodifiable({
         for (final entry in memberships.entries)
           entry.key: Set.unmodifiable(entry.value),
       });

  /// The agent name (e.g. `goal_builder`).
  final String name;

  /// The hosting device id (e.g. `macbook`).
  final String deviceId;

  /// The DM public key published in the roster entry (§7), or null until
  /// provisioned. Keyed by [address], never the bare name (v1.1).
  final String? dmPub;

  /// Per-network channel memberships (networkId → channel ids) — the
  /// visibility basis for shared networks.
  final Map<String, Set<String>> memberships;

  /// The full §1 address: `<agentName>@<deviceId>`.
  String get address => agentAddress(name, deviceId);

  @override
  String toString() =>
      'AgentRegistration($address${dmPub == null ? '' : ' dmPub:<set>'})';
}

/// One registered session (owner-lease surface, §5): exposed sessions are
/// the ones a remote viewer can attach to. A session always belongs to an
/// agent ([agentAddress]) — unregistering that agent cascades the session.
final class SessionRegistration {
  /// Registers session [id] running under agent [agentAddressOf].
  const SessionRegistration({required this.id, required String agentAddressOf})
    : agentAddress = agentAddressOf;

  /// The local session id (the fabric mailbox/session identifier).
  final String id;

  /// The agent address this session runs under (`<name>@<deviceId>`).
  final String agentAddress;
}

/// One exposed agent in the published roster projection (§4 roster
/// snapshot): the composite identity, the DM public key, and the session
/// ids that ride along (exposed sessions of exposed agents only).
final class AgentRosterEntry {
  /// Builds a projection entry; [sessions] lists exposed session ids.
  const AgentRosterEntry({
    required this.name,
    required this.address,
    this.dmPub,
    this.sessions = const [],
  });

  /// The agent name.
  final String name;

  /// The full `<agentName>@<deviceId>` address.
  final String address;

  /// The published DM public key (§7), or null.
  final String? dmPub;

  /// Exposed session ids attached to this agent.
  final List<String> sessions;

  @override
  String toString() =>
      'AgentRosterEntry($address, sessions: $sessions'
      '${dmPub == null ? '' : ', dmPub:<set>'})';
}

/// What the connector publishes for ONE network: the exposed-only roster
/// projection ([DeviceRegistry.rosterProjection]).
final class NetworkRoster {
  /// Builds the projection for [networkId].
  const NetworkRoster({
    required this.networkId,
    required this.kind,
    required this.agents,
  });

  /// The projected network.
  final String networkId;

  /// The network kind the projection used.
  final NetworkKind kind;

  /// Exposed agents, each with their exposed sessions.
  final List<AgentRosterEntry> agents;

  @override
  String toString() => 'NetworkRoster($networkId, ${agents.length} agents)';
}

/// What mutated in the registry — presence propagation listens to this and
/// republishes within one heartbeat (§6: "Toggles propagate in the next
/// presence/roster frame").
enum DeviceRegistryChangeKind {
  /// An agent was registered.
  agentRegistered,

  /// An agent was unregistered (its sessions cascaded away).
  agentUnregistered,

  /// A session was registered.
  sessionRegistered,

  /// A session was unregistered.
  sessionUnregistered,

  /// An exposure flag flipped (agent or session).
  exposureChanged,

  /// An agent's channel memberships changed (shared-network visibility).
  agentChannelsChanged,

  /// A network's kind was configured or re-configured.
  networkKindChanged,
}

/// One registry mutation, broadcast on [DeviceRegistry.changes].
final class DeviceRegistryChange {
  /// Builds a change record; the nullable fields name what mutated.
  const DeviceRegistryChange({
    required this.kind,
    this.networkId,
    this.agentAddressOf,
    this.sessionId,
  });

  /// What happened.
  final DeviceRegistryChangeKind kind;

  /// The affected network, when the mutation is network-scoped.
  final String? networkId;

  /// The affected agent address, when an agent mutated.
  final String? agentAddressOf;

  /// The affected session id, when a session mutated.
  final String? sessionId;

  @override
  String toString() =>
      'DeviceRegistryChange($kind'
      '${networkId == null ? '' : ' network=$networkId'}'
      '${agentAddressOf == null ? '' : ' agent=$agentAddressOf'}'
      '${sessionId == null ? '' : ' session=$sessionId'})';
}

/// The local exposure registry (contract §2/§6). Holds agents, sessions and
/// their per-network exposure flags; [rosterProjection] yields the
/// exposed-only view the connector publishes, and [changes] lets the
/// presence engine re-publish within one heartbeat.
final class DeviceRegistry {
  final _agents = <String, AgentRegistration>{};
  final _sessions = <String, SessionRegistration>{};

  /// Explicit exposure overrides per entry: address → (network → flag).
  /// Absent = derive from the network-kind default.
  final _agentExposure = <String, Map<String, bool>>{};
  final _sessionExposure = <String, Map<String, bool>>{};
  final _networkKinds = <String, NetworkKind>{};
  final _changes = StreamController<DeviceRegistryChange>.broadcast();

  /// Fires on every registry mutation. Never emits after [dispose].
  Stream<DeviceRegistryChange> get changes => _changes.stream;

  /// The registered agents (unmodifiable view).
  List<AgentRegistration> get agents => List.unmodifiable(_agents.values);

  /// The registered sessions (unmodifiable view).
  List<SessionRegistration> get sessions => List.unmodifiable(_sessions.values);

  /// The configured network ids (unmodifiable view) — the presence
  /// projection iterates these.
  List<String> get networkIds => List.unmodifiable(_networkKinds.keys);

  /// Configures [networkId]'s membership kind. Unconfigured networks use
  /// the conservative shared default (deny-by-default).
  void configureNetwork(String networkId, NetworkKind kind) {
    _networkKinds[networkId] = kind;
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.networkKindChanged,
        networkId: networkId,
      ),
    );
  }

  /// The configured kind of [networkId], or null when unconfigured.
  NetworkKind? kindOf(String networkId) => _networkKinds[networkId];

  /// The effective default for [networkId] — unconfigured counts as shared.
  NetworkKind _effectiveKind(String networkId) =>
      _networkKinds[networkId] ?? NetworkKind.shared;

  /// Registers agent [name] on device [deviceId] (see
  /// [AgentRegistration]). Re-registering the same address updates dmPub
  /// and memberships in place (one registration per address).
  void registerAgent(
    String name,
    String deviceId, {
    String? dmPub,
    Map<String, Set<String>> memberships = const {},
  }) {
    final registration = AgentRegistration(
      name: name,
      deviceId: deviceId,
      dmPub: dmPub,
      memberships: memberships,
    );
    _agents[registration.address] = registration;
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.agentRegistered,
        agentAddressOf: registration.address,
      ),
    );
  }

  /// Removes agent [name] on device [deviceId]; attached sessions cascade
  /// away with it (§5: offline sessions are not exposed). No-op when the
  /// address is unknown.
  void unregisterAgent(String name, String deviceId) {
    final address = agentAddress(name, deviceId);
    if (_agents.remove(address) == null) return;
    _agentExposure.remove(address);
    _sessions.removeWhere((_, session) => session.agentAddress == address);
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.agentUnregistered,
        agentAddressOf: address,
      ),
    );
  }

  /// Replaces agent [name]'s channel memberships on [networkId] — the
  /// shared-network visibility basis (§6: "agents follow channel
  /// membership visibility").
  void setAgentChannels(
    String name,
    String networkId,
    Iterable<String> channels,
  ) {
    final address = _addressOfAgent(name);
    if (address == null) return;
    final existing = _agents[address]!;
    _agents[address] = AgentRegistration(
      name: existing.name,
      deviceId: existing.deviceId,
      dmPub: existing.dmPub,
      memberships: {...existing.memberships, networkId: Set.of(channels)},
    );
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.agentChannelsChanged,
        networkId: networkId,
        agentAddressOf: address,
      ),
    );
  }

  /// Registers a session (see [SessionRegistration]). Re-registering the
  /// same id re-attaches it (one registration per id).
  void registerSession(SessionRegistration registration) {
    _sessions[registration.id] = registration;
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.sessionRegistered,
        sessionId: registration.id,
      ),
    );
  }

  /// Removes session [id]. No-op when unknown.
  void unregisterSession(String id) {
    if (_sessions.remove(id) == null) return;
    _sessionExposure.remove(id);
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.sessionUnregistered,
        sessionId: id,
      ),
    );
  }

  /// Sets agent [name]'s exposure on [networkId], overriding the
  /// network-kind default (§0.2 per-agent toggle: default ON personal).
  void setAgentExposed(
    String networkId,
    String name,
    String deviceId, {
    required bool exposed,
  }) {
    final address = agentAddress(name, deviceId);
    (_agentExposure[address] ??= {})[networkId] = exposed;
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.exposureChanged,
        networkId: networkId,
        agentAddressOf: address,
      ),
    );
  }

  /// Sets session [id]'s exposure on [networkId] (§6: sessions default OFF
  /// on shared networks, ON on the personal one).
  void setSessionExposed(String networkId, String id, {required bool exposed}) {
    (_sessionExposure[id] ??= {})[networkId] = exposed;
    _changes.add(
      DeviceRegistryChange(
        kind: DeviceRegistryChangeKind.exposureChanged,
        networkId: networkId,
        sessionId: id,
      ),
    );
  }

  /// Whether agent [name] publishes on [networkId]: the explicit flag when
  /// set, else the network-kind default — personal ON; shared/unknown only
  /// when the agent is a member of at least one channel there.
  bool isAgentExposed(String networkId, String name, String deviceId) {
    final address = agentAddress(name, deviceId);
    final flag = _agentExposure[address]?[networkId];
    if (flag != null) return flag;
    if (_effectiveKind(networkId) == NetworkKind.personal) return true;
    return _agents[address]?.memberships[networkId]?.isNotEmpty ?? false;
  }

  /// Whether session [id] publishes on [networkId]: the explicit flag when
  /// set, else ON for personal networks and OFF for shared/unknown ones.
  bool isSessionExposed(String networkId, String id) {
    final flag = _sessionExposure[id]?[networkId];
    if (flag != null) return flag;
    return _effectiveKind(networkId) == NetworkKind.personal;
  }

  /// The exposed-only roster projection for [networkId] (§4 roster
  /// snapshot, AC3): exposed agents only; a session rides its agent's
  /// entry only when the AGENT is exposed too — an exposed session under a
  /// hidden agent stays unpublished.
  NetworkRoster rosterProjection(String networkId) {
    final entries = <AgentRosterEntry>[];
    for (final agent in _agents.values) {
      if (!isAgentExposed(networkId, agent.name, agent.deviceId)) continue;
      final exposedSessions = <String>[];
      for (final session in _sessions.values) {
        if (session.agentAddress != agent.address) continue;
        if (isSessionExposed(networkId, session.id)) {
          exposedSessions.add(session.id);
        }
      }
      entries.add(
        AgentRosterEntry(
          name: agent.name,
          address: agent.address,
          dmPub: agent.dmPub,
          sessions: exposedSessions,
        ),
      );
    }
    return NetworkRoster(
      networkId: networkId,
      kind: _effectiveKind(networkId),
      agents: entries,
    );
  }

  String? _addressOfAgent(String name) {
    for (final address in _agents.keys) {
      if (_agents[address]!.name == name) return address;
    }
    return null;
  }

  /// Closes the change stream; the registry is unusable afterwards.
  void dispose() => _changes.close();
}
