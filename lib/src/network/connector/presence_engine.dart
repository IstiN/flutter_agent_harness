/// The three-level presence engine of the machine connector (contract
/// `docs/fa_network_connector.md` §5): machine `online/degraded/offline`,
/// agent `live/busy/offline`, session `live/wake-on-DM/offline`.
///
/// Rules encoded from §5:
/// - a `presence` frame every 15–30 s ([presenceHeartbeatInterval] pins
///   20 s) and IMMEDIATELY on any state flip;
/// - machine degraded = socket lost while local agents keep working; the
///   offline flip happens when the grace window expires
///   ([defaultOfflineGrace], ~45 s) — a clean shutdown deregisters
///   immediately;
/// - agent presence is proxied from the local fabric registration state
///   (`busy` = run in progress, mail still accepted) — hosts feed
///   [PresenceEngine.setAgentState];
/// - session presence derives from exposure + lease state pulled through
///   the injectable delegates at frame-build time ("presence truth =
///   server receive time", so frames carry no client wall-clock claims
///   beyond the transport stamp);
/// - clock and timers are injectable seams ([ConnectorClock],
///   [ConnectorTimers]) — tests drive a fake clock, hosts get the system
///   defaults. NOTE: timers are ALWAYS wait-for-frame style; nothing here
///   uses read-timeouts against sockets (backend field note: cancelling a
///   socket read closes the connection — liveness is the 20 s ping/pong
///   application frames, half-open drop is the server's job).
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:async';

import 'envelope.dart';

/// Injectable clock seam (tests freeze time; hosts use [SystemClock]).
abstract interface class ConnectorClock {
  /// The current UTC instant.
  DateTime now();
}

/// The system clock, UTC.
final class SystemClock implements ConnectorClock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// One cancellable timer handle ([ConnectorTimers] returns these).
abstract interface class ConnectorTimer {
  /// Cancels the timer; idempotent.
  void cancel();
}

/// Adapter binding the interface to a cancel closure.
final class _FunctionTimer implements ConnectorTimer {
  _FunctionTimer(this._cancel);

  final void Function() _cancel;

  @override
  void cancel() => _cancel();
}

/// Injectable timer seam (tests fire ticks manually; hosts use real
/// `dart:async` timers — never socket read-timeouts).
abstract interface class ConnectorTimers {
  /// A repeating [interval] timer.
  ConnectorTimer periodic(Duration interval, void Function() onTick);

  /// A one-shot timer.
  ConnectorTimer delayed(Duration duration, void Function() onFire);
}

/// Real `dart:async` timers.
final class SystemTimers implements ConnectorTimers {
  const SystemTimers();

  @override
  ConnectorTimer periodic(Duration interval, void Function() onTick) {
    final timer = Timer.periodic(interval, (_) => onTick());
    return _FunctionTimer(timer.cancel);
  }

  @override
  ConnectorTimer delayed(Duration duration, void Function() onFire) {
    final timer = Timer(duration, onFire);
    return _FunctionTimer(timer.cancel);
  }
}

/// Machine-level presence (§5): `online` = socket + heartbeats,
/// `degraded` = socket lost, local agents keep working (the server infers
/// it while its grace window runs), `offline` = grace expired or clean
/// shutdown.
enum MachinePresence {
  /// Socket up, heartbeats flowing.
  online('online'),

  /// Socket lost; grace window running (~45 s).
  degraded('degraded'),

  /// Grace expired or clean shutdown.
  offline('offline');

  const MachinePresence(this.wireName);

  /// The wire form in presence frame payloads.
  final String wireName;

  /// Parses a payload state; null for unknown values.
  static MachinePresence? tryParse(String wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// Agent-level presence (§5): proxied from the local fabric registration
/// state. Named AgentRunState to stay distinct from the messaging fabric's
/// reporting enum.
enum AgentRunState {
  /// Registered, no run in progress.
  live('live'),

  /// A run is in progress; mail is still accepted (steering semantics).
  busy('busy'),

  /// Not registered locally.
  offline('offline');

  const AgentRunState(this.wireName);

  /// The wire form in presence frame payloads.
  final String wireName;

  /// Parses a payload state; null for unknown values.
  static AgentRunState? tryParse(String wireName) {
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// Session-level presence (§5) for exposed sessions: `live` = owner lease
/// active, `wakeOnDm` = exposed, no live lease, `offline` = device offline.
enum ConnectorSessionPresence {
  /// Owner lease active.
  live('live'),

  /// Exposed, no live lease — a DM wakes it (§8).
  wakeOnDm('wake_on_dm'),

  /// Device offline or session unexposed.
  offline('offline');

  const ConnectorSessionPresence(this.wireName);

  /// The wire form in presence frame payloads.
  final String wireName;

  /// Parses a payload state; null for unknown values. REST roster writers
  /// historically used `wake-on-DM`, while presence frames use `wake_on_dm`;
  /// both spellings denote the same exposed-but-not-running session.
  static ConnectorSessionPresence? tryParse(String wireName) {
    if (wireName == 'wake-on-DM' || wireName == 'wakeOnDm') {
      return ConnectorSessionPresence.wakeOnDm;
    }
    for (final value in values) {
      if (value.wireName == wireName) return value;
    }
    return null;
  }
}

/// Optional, additive display metadata for one exposed session. Older peers
/// send only `id` + `state`; decoders therefore treat every field as optional
/// and the UI falls back to a short session id when no title is available.
final class ConnectorSessionMetadata {
  /// Builds session display metadata.
  const ConnectorSessionMetadata({this.title, this.path, this.lastActivity});

  /// Human-readable session title (custom, CLI, or the host's derived title).
  final String? title;

  /// Project/working-directory path shown as the session row subtitle.
  final String? path;

  /// Last transcript activity, used for recency ordering and relative time.
  final DateTime? lastActivity;

  /// Whether no display field is present.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (path == null || path!.isEmpty) &&
      lastActivity == null;

  /// Decodes the additive session fields without rejecting legacy rows.
  static ConnectorSessionMetadata? fromJson(Object? value) {
    if (value is! Map) return null;
    final rawTitle = value['title'];
    final rawPath = value['path'];
    final rawActivity = value['lastActivity'];
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : null;
    final path = rawPath is String && rawPath.trim().isNotEmpty
        ? rawPath.trim()
        : null;
    final activity = rawActivity is String
        ? DateTime.tryParse(rawActivity)
        : null;
    final metadata = ConnectorSessionMetadata(
      title: title,
      path: path,
      lastActivity: activity,
    );
    return metadata.isEmpty ? null : metadata;
  }

  /// Wire fields merged into a roster/presence session row.
  Map<String, Object?> toJson() => {
    if (title != null && title!.isNotEmpty) 'title': title,
    if (path != null && path!.isNotEmpty) 'path': path,
    if (lastActivity != null)
      'lastActivity': lastActivity!.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is ConnectorSessionMetadata &&
      other.title == title &&
      other.path == path &&
      other.lastActivity == lastActivity;

  @override
  int get hashCode => Object.hash(title, path, lastActivity);
}

/// One machine presence frame's payload, built and parsed both ways: the
/// machine state with agent presence riding inside (§5), addressed
/// device-level (no `network`/`channel` on the envelope, §3).
final class PresenceFrame {
  /// Builds a frame payload snapshot; [agents] maps agent address → run
  /// state, [sessions] maps exposed session id → derived presence, and
  /// [sessionMetadata] carries the optional additive display fields.
  const PresenceFrame({
    required this.msgId,
    required this.ts,
    required this.machine,
    this.agents = const {},
    this.sessions = const {},
    this.sessionMetadata = const {},
  });

  /// The frame id (also the dedup key).
  final String msgId;

  /// RFC3339 UTC stamp of the build instant.
  final String ts;

  /// The machine's state.
  final MachinePresence machine;

  /// Agent presence riding inside the machine frame (§5).
  final Map<String, AgentRunState> agents;

  /// Exposed-session presence (lease-derived).
  final Map<String, ConnectorSessionPresence> sessions;

  /// Display metadata keyed by exposed session id. This map may be sparser
  /// than [sessions]; legacy peers simply leave it empty.
  final Map<String, ConnectorSessionMetadata> sessionMetadata;

  /// Builds the wire envelope (kind `presence`, device-level).
  NetworkEnvelope toEnvelope({IdFactory idFactory = defaultIdFactory}) =>
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.presence,
        msgId: msgId,
        ts: ts,
        payload: {
          'machine': machine.wireName,
          if (agents.isNotEmpty)
            'agents': [
              for (final entry in agents.entries)
                {'address': entry.key, 'state': entry.value.wireName},
            ],
          if (sessions.isNotEmpty)
            'sessions': [
              for (final entry in sessions.entries)
                {
                  'id': entry.key,
                  'state': entry.value.wireName,
                  ...?sessionMetadata[entry.key]?.toJson(),
                },
            ],
        },
      );

  /// Parses a presence envelope's payload; null when the payload does not
  /// carry a machine state.
  static PresenceFrame? fromEnvelope(NetworkEnvelope envelope) {
    if (envelope.kind != NetworkEnvelopeKind.presence) return null;
    final machine = MachinePresence.tryParse(
      '${envelope.payload['machine'] ?? ''}',
    );
    if (machine == null) return null;
    AgentRunState? parseAgent(Object? node) =>
        node is Map ? AgentRunState.tryParse('${node['state'] ?? ''}') : null;
    ConnectorSessionPresence? parseSession(Object? node) => node is Map
        ? ConnectorSessionPresence.tryParse('${node['state'] ?? ''}')
        : null;
    return PresenceFrame(
      msgId: envelope.msgId,
      ts: envelope.ts,
      machine: machine,
      agents: {
        for (final node in (envelope.payload['agents'] as List? ?? const []))
          if (node is Map && parseAgent(node) != null)
            '${node['address']}': parseAgent(node)!,
      },
      sessions: {
        for (final node in (envelope.payload['sessions'] as List? ?? const []))
          if (node is Map && parseSession(node) != null)
            '${node['id']}': parseSession(node)!,
      },
      sessionMetadata: {
        for (final node in (envelope.payload['sessions'] as List? ?? const []))
          if (node is Map &&
              node['id'] is String &&
              ConnectorSessionMetadata.fromJson(node) != null)
            node['id'] as String: ConnectorSessionMetadata.fromJson(node)!,
      },
    );
  }

  @override
  String toString() =>
      'PresenceFrame(machine: ${machine.wireName}, '
      'agents: ${agents.length}, sessions: ${sessions.length})';
}

/// The presence engine (§5): holds the machine lifecycle, the proxied
/// agent states and the exposure/lease delegates; emits [PresenceFrame]s
/// on every state flip immediately plus a heartbeat snapshot every
/// [presenceHeartbeatInterval]. Composition wires the delegates from the
/// device registry (exposure) and the local lease store (owner leases).
final class PresenceEngine {
  /// Builds an engine. [clock]/[timers] default to the system seams;
  /// [exposedSessions] is pulled at every frame build (the exposed session
  /// ids from the device registry) and [liveLeases] at every build too
  /// (session ids with an active owner lease). A null delegate means no
  /// exposed sessions / no leases.
  PresenceEngine({
    ConnectorClock? clock,
    ConnectorTimers? timers,
    this.heartbeatInterval = presenceHeartbeatInterval,
    this.offlineGrace = defaultOfflineGrace,
    this.exposedSessions,
    this.liveLeases,
    this.idFactory = defaultIdFactory,
  }) : _clock = clock ?? const SystemClock(),
       _timers = timers ?? const SystemTimers();

  /// Heartbeat period — inside the contract §5 window of 15–30 s.
  static const presenceHeartbeatInterval = Duration(seconds: 20);

  /// Machine degraded → offline grace window (§5: ~45 s, server-side
  /// inference runs the same window).
  static const defaultOfflineGrace = Duration(seconds: 45);

  /// How often the heartbeat frame goes out.
  final Duration heartbeatInterval;

  /// How long a lost socket stays degraded before flipping offline.
  final Duration offlineGrace;

  /// Frame id factory (injectable for tests).
  final IdFactory idFactory;

  final ConnectorClock _clock;
  final ConnectorTimers _timers;

  /// Pulled at EVERY frame build: the exposed session ids (wired by the
  /// composition root from the device registry; §6 within-one-heartbeat
  /// propagation).
  Set<String> Function()? exposedSessions;

  /// Pulled at EVERY frame build: session ids with an active owner lease
  /// (§5, issue #428 semantics).
  Set<String> Function()? liveLeases;

  /// Optional display metadata for exposed sessions. The delegate is pulled
  /// with the exposure/lease views so create/rename/activity updates ride the
  /// next immediate roster update or heartbeat without a wire-version bump.
  Map<String, ConnectorSessionMetadata> Function()? sessionMetadata;

  MachinePresence _machine = MachinePresence.offline;
  final _agents = <String, AgentRunState>{};
  final _frames = StreamController<PresenceFrame>.broadcast();
  ConnectorTimer? _heartbeat;
  ConnectorTimer? _grace;
  bool _started = false;

  /// Fires on every heartbeat and IMMEDIATELY on every state flip (§5).
  Stream<PresenceFrame> get frames => _frames.stream;

  /// The current machine state.
  MachinePresence get machineState => _machine;

  /// Whether the engine's timers are running.
  bool get isRunning => _started;

  /// Starts the heartbeat; emits an initial snapshot so the server learns
  /// our state at once. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _emit();
    _heartbeat = _timers.periodic(heartbeatInterval, _emit);
  }

  /// The upstream socket is up: machine online (immediate frame, grace
  /// timer cancelled).
  void markConnected() {
    _cancelGrace();
    _transition(MachinePresence.online);
  }

  /// The upstream socket dropped: machine degraded (immediate frame) and
  /// the offline grace window starts.
  void markSocketLost() {
    _cancelGrace();
    _transition(MachinePresence.degraded);
    _grace = _timers.delayed(offlineGrace, () {
      _grace = null;
      _transition(MachinePresence.offline);
    });
  }

  /// Clean shutdown: deregisters IMMEDIATELY (§5) — one offline frame and
  /// every timer stops. Idempotent.
  void stop({bool clean = true}) {
    if (!_started) return;
    _started = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _cancelGrace();
    if (clean && _machine != MachinePresence.offline) {
      _transition(MachinePresence.offline);
    }
  }

  /// Proxies one agent's run state (live/busy/offline); a flip emits
  /// immediately.
  void setAgentState(String address, AgentRunState state) {
    if (_agents[address] == state) return;
    _agents[address] = state;
    _emit();
  }

  /// Bulk variant of [setAgentState] (one frame for the whole update).
  void setAgentStates(Map<String, AgentRunState> states) {
    var changed = false;
    states.forEach((address, state) {
      if (_agents[address] != state) {
        _agents[address] = state;
        changed = true;
      }
    });
    if (changed) _emit();
  }

  /// The current full snapshot (frame payload built from machine state,
  /// proxied agent states, exposure + lease delegates).
  PresenceFrame snapshot() {
    final exposed = exposedSessions?.call() ?? const <String>{};
    final leases = liveLeases?.call() ?? const <String>{};
    final sessions = <String, ConnectorSessionPresence>{
      for (final id in exposed)
        id: _machine == MachinePresence.offline
            ? ConnectorSessionPresence.offline
            : leases.contains(id)
            ? ConnectorSessionPresence.live
            : ConnectorSessionPresence.wakeOnDm,
    };
    final metadata = sessionMetadata?.call() ?? const {};
    return PresenceFrame(
      msgId: idFactory(),
      ts: rfc3339Timestamp(_clock.now()),
      machine: _machine,
      agents: Map.unmodifiable(_agents),
      sessions: sessions,
      sessionMetadata: {
        for (final id in exposed)
          if (metadata[id] != null) id: metadata[id]!,
      },
    );
  }

  /// Closes the frame stream (after [stop]).
  void dispose() {
    stop();
    _frames.close();
  }

  /// Emits a snapshot frame immediately (exposure toggles propagate
  /// within one heartbeat — the composition calls this on registry
  /// changes; §6).
  void publishNow() => _emit();

  void _emit() => _frames.add(snapshot());

  void _transition(MachinePresence next) {
    if (_machine == next) return;
    _machine = next;
    _emit();
  }

  void _cancelGrace() {
    _grace?.cancel();
    _grace = null;
  }
}
