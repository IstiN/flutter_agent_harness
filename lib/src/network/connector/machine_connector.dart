/// The composition root of the machine connector (contract
/// `docs/fa_network_connector.md` §10): wires registry + ACL + mux +
/// outbox + presence + upstream into one device-connector surface —
/// `start()`/`stop()`, `sendMail(...)`, `registerLocalSink(...)`, inbound
/// mail → ACL → sink write → ack only after the sink confirms, and the
/// presence publisher pulling registry + lease state via delegates.
///
/// Data flow (§3–§6):
/// - inbound: upstream frames → mux demux (msgId dedup, route by
///   `(network, channel, to)`) → ACL sanitize → local sink write →
///   `acknowledge` AFTER the sink completes (§3 ack-after-write); a
///   throwing sink is NOT acked so the server redelivers (no lost input);
///   an ACL rejection is reported AND acked (no redelivery loop of
///   refused payloads); unrouted mail is answered with an `error` frame
///   referencing the mail's msgId;
/// - outbound: `sendMail` mints the msgId ONCE (it IS the fanet1 frameId
///   — contract v1.1), puts it in the outbox and drains head-first while
///   the upstream is ready; a failed/lost link leaves the frame queued
///   and the reconnect re-kicks the drain — order intact, ids stable
///   (AC5);
/// - presence: the engine emits frames on flips + heartbeat; delegates
///   pull exposure (device registry) and owner leases (lease store);
///   registry toggles trigger an immediate republish (§6: within one
///   heartbeat).
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:async';

import 'connector_mux.dart';
import 'device_registry.dart';
import 'envelope.dart';
import 'exposure_acl.dart';
import 'offline_outbox.dart';
import 'presence_engine.dart';
import 'upstream_client.dart';

/// Decodes one inbound mail frame to the plain text the ACL and the sink
/// see. The default ([plainCiphertextDecoder]) treats the ciphertext as
/// plain text (personal-network/dev mode); the fanet1 device-DM codec plugs
/// into this seam and returns authenticated metadata with the full payload.
typedef MailDecoder = FutureOr<DecodedMail> Function(NetworkEnvelope envelope);

/// The complete decrypted mail payload and its optional DM routing metadata.
///
/// [payload] deliberately retains a structured DM wrapper: the connector ACL
/// must inspect the complete decrypted value, not only an extracted `text`
/// field. DM senders use [sessionId] and [senderPubkey] to construct durable
/// reply routes; [threaded] preserves the app's legacy-raw-reply contract.
final class DecodedMail {
  const DecodedMail({
    required this.payload,
    this.sessionId,
    this.senderPubkey,
    this.threaded = false,
  });

  /// Complete decrypted payload (or the opaque plaintext in pass-through
  /// mode). This is the value the remote-write ACL sanitizes.
  final String payload;

  /// Target session carried inside an encrypted DM wrapper, when present.
  final String? sessionId;

  /// Base64 X25519 sender public key from an authenticated fanet1 frame.
  final String? senderPubkey;

  /// Whether the sender opted into structured/threaded DM replies.
  final bool threaded;
}

/// A permanent, credential-free inbound mail decode rejection.
///
/// Hosts ack these failures to prevent malicious or undecryptable payloads
/// from redelivering forever. Key-store and other transient failures MUST NOT
/// be converted to this type. [reason] never contains plaintext or keys.
final class MailDecodeException implements Exception {
  const MailDecodeException(this.reason);

  /// Stable safe-to-log rejection reason.
  final String reason;

  @override
  String toString() => 'MailDecodeException: $reason';
}

/// The plain-ciphertext pass-through decoder.
DecodedMail plainCiphertextDecoder(NetworkEnvelope envelope) =>
    DecodedMail(payload: envelope.ciphertext ?? '');

/// Pulls the session ids with an ACTIVE owner lease (§5, issue #428
/// semantics). Polled by the presence publisher at start, upstream attach
/// and registry changes.
typedef SessionLeaseDelegate = Future<Set<String>> Function();

/// One accepted inbound mail handed to a local sink: the original frame
/// plus the ACL-sanitized plain user text (remote writers are viewers —
/// §6).
final class InboundMail {
  const InboundMail({
    required this.envelope,
    required this.text,
    this.sessionId,
    this.senderPubkey,
    this.threaded = false,
  });

  /// The wire frame (msgId/network/channel/from/to as received).
  final NetworkEnvelope envelope;

  /// The plain user text after connector-side sanitization.
  final String text;

  /// Target session from the authenticated DM wrapper, when present.
  final String? sessionId;

  /// Base64 X25519 sender public key from the authenticated fanet1 frame.
  final String? senderPubkey;

  /// Whether replies should retain the structured DM thread wrapper.
  final bool threaded;

  /// The frame id (dedup/ack key).
  String get msgId => envelope.msgId;

  @override
  String toString() => 'InboundMail($msgId text:<${text.length} chars>)';
}

/// One ACL-refused remote write (§6 AC6 reporting).
final class RejectedMail {
  const RejectedMail({required this.envelope, required this.reason});

  /// The refused frame.
  final NetworkEnvelope envelope;

  /// The connector-side refusal reason (server checks are structural
  /// only — content sanitization is connector-only per amendment v1.1).
  final String reason;

  @override
  String toString() => 'RejectedMail(${envelope.msgId}: $reason)';
}

/// The machine connector composition root.
final class MachineConnector {
  /// Builds a connector. [registry] and [upstream] are required; the mux,
  /// outbox and presence engine default to fresh instances. [decodeMail]
  /// defaults to the plain-ciphertext pass-through; [leases] polls the
  /// owner-lease store; [liveLeasesSync] overrides the lease view with a
  /// sync delegate when a host prefers push updates.
  MachineConnector({
    required this.registry,
    required this.upstream,
    ConnectorMux? mux,
    OutboxStore? outbox,
    PresenceEngine? presence,
    this.decodeMail = plainCiphertextDecoder,
    this.leases,
    this._liveLeasesSync,
    this.idFactory = defaultIdFactory,
    void Function(String)? onLog,
  }) : mux =
           mux ??
           ConnectorMux(
             onUnrouted: (envelope) => onLog?.call(
               'unrouted mail (${envelope.msgId}) on '
               '${envelope.network}/${envelope.channel}',
             ),
             onInvalid: (envelope, problems) => onLog?.call(
               'invalid frame dropped (${envelope.msgId}): '
               '${problems.join('; ')}',
             ),
           ),
       outbox = outbox ?? MemoryOutboxStore(),
       presence = presence ?? PresenceEngine(idFactory: idFactory),
       _onLog = onLog {
    // The composition owns the presence pull: exposure from the registry,
    // leases from the (cached) async delegate.
    this.presence.exposedSessions = _exposedSessionIds;
    this.presence.liveLeases = () => _leaseCache;
  }

  /// The local exposure registry (§2/§6).
  final DeviceRegistry registry;

  /// The upstream device socket client (§4).
  final ConnectorUpstreamClient upstream;

  /// The envelope mux (§3 demux/dedup/ordering).
  final ConnectorMux mux;

  /// The offline outbox (§4/§10): frames minted while disconnected.
  final OutboxStore outbox;

  /// The presence engine (§5).
  final PresenceEngine presence;

  /// Inbound mail decoder seam (DM fanet1 rides a later slice, §7).
  final MailDecoder decodeMail;

  /// Owner-lease poll (§5): session ids with an active lease.
  final SessionLeaseDelegate? leases;

  /// Frame id factory.
  final IdFactory idFactory;

  final void Function(String)? _onLog;
  final Set<String> Function()? _liveLeasesSync;
  var _leaseCache = const <String>{};
  StreamSubscription<NetworkEnvelope>? _inboundSubscription;
  StreamSubscription<ConnectorLinkState>? _stateSubscription;
  StreamSubscription<PresenceFrame>? _presenceSubscription;
  StreamSubscription<DeviceRegistryChange>? _registrySubscription;
  bool _draining = false;
  bool _started = false;

  final _rejections = StreamController<RejectedMail>.broadcast();
  final _rosterFrames = StreamController<NetworkEnvelope>.broadcast();
  final _presenceFrames = StreamController<NetworkEnvelope>.broadcast();
  final _wakeHints = StreamController<NetworkEnvelope>.broadcast();
  final _dmMail = StreamController<InboundMail>.broadcast(sync: true);

  /// ACL-refused remote writes (AC6 reporting).
  Stream<RejectedMail> get rejections => _rejections.stream;

  /// Roster snapshots/patches from the server (§4).
  Stream<NetworkEnvelope> get rosterFrames => _rosterFrames.stream;

  /// Presence frames from the server (network-wide presence view).
  Stream<NetworkEnvelope> get presenceFrames => _presenceFrames.stream;

  /// Wake hints (§8; mobile/extension wake rides a later slice).
  Stream<NetworkEnvelope> get wakeHints => _wakeHints.stream;

  /// Post-sink observation of accepted inbound mail.
  ///
  /// This is NOT a delivery mechanism: the owning [registerLocalSink] future
  /// has already completed when an event is emitted, and the connector acks
  /// immediately afterwards. Listeners must never be responsible for mailbox
  /// writes or delivery backpressure.
  Stream<InboundMail> get dmMail => _dmMail.stream;

  /// Whether the upstream link is ready (handshake complete).
  bool get isConnected => upstream.isReady;

  /// Whether [start] is active.
  bool get isRunning => _started;

  /// Frames still queued in the offline outbox (AC5 assertion seam).
  Future<int> pendingMailCount() => outbox.pendingCount();

  /// Starts everything: upstream connect loop, presence heartbeat, frame
  /// wiring and the outbox drain. Idempotent.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _refreshLeases();
    _registrySubscription = registry.changes.listen((_) {
      presence.publishNow();
      unawaited(_refreshLeases());
    });
    _presenceSubscription = presence.frames.listen(
      (frame) => unawaited(_publishPresence(frame)),
    );
    _inboundSubscription = upstream.inbound.listen(_handleFrame);
    _stateSubscription = upstream.stateChanges.listen((state) {
      switch (state) {
        case ConnectorLinkState.connected:
          presence.markConnected();
          unawaited(_refreshLeases());
          unawaited(_drainOutbox());
        case ConnectorLinkState.disconnected:
          presence.markSocketLost();
        case ConnectorLinkState.connecting:
        case ConnectorLinkState.handshaking:
          break;
      }
    });
    await upstream.start();
    presence.start();
  }

  /// Clean stop: the machine deregisters immediately server-side (§5).
  /// Idempotent.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _inboundSubscription?.cancel();
    await _stateSubscription?.cancel();
    await _presenceSubscription?.cancel();
    await _registrySubscription?.cancel();
    _inboundSubscription = null;
    _stateSubscription = null;
    _presenceSubscription = null;
    _registrySubscription = null;
    presence.stop();
    await upstream.stop();
  }

  /// Queues one outbound mail frame and drains while the link is up.
  /// [ciphertext] is the opaque fanet1 frame (§7); the minted [msgId] is
  /// returned and is REUSED byte-for-byte on every retry (contract v1.1 —
  /// the id is the frameId/HKDF salt/AAD/dedup key).
  Future<String> sendMail({
    required String network,
    required String channel,
    required String from,
    String? to,
    String? ciphertext,
    FutureOr<String> Function(String frameId)? ciphertextFor,
  }) async {
    if ((ciphertext == null) == (ciphertextFor == null)) {
      throw ArgumentError('provide exactly one of ciphertext or ciphertextFor');
    }
    final msgId = idFactory();
    final body = ciphertext ?? await ciphertextFor!(msgId);
    final envelope = NetworkEnvelope(
      kind: NetworkEnvelopeKind.mail,
      msgId: msgId,
      network: network,
      channel: channel,
      from: from,
      to: to,
      ts: rfc3339Timestamp(DateTime.now().toUtc()),
      ciphertext: body,
    )..requireValid();
    await outbox.put(OutboxEntry(envelope: envelope));
    unawaited(_drainOutbox());
    return envelope.msgId;
  }

  /// Registers a local sink for `(network, channel, to)` mail: the write
  /// is ACL-sanitized plain user text (§6); the connector acks ONLY after
  /// [sink] completes — a throw means no ack, and the server redelivers
  /// (§3/§4: no lost input).
  SinkRegistration registerLocalSink({
    required String network,
    required String channel,
    String? to,
    required Future<void> Function(InboundMail mail) sink,
  }) => mux.registerSink(
    MailRoute(network: network, channel: channel, to: to ?? ''),
    (envelope) => _deliverToSink(envelope, sink),
  );

  Future<void> _deliverToSink(
    NetworkEnvelope envelope,
    Future<void> Function(InboundMail mail) sink,
  ) async {
    final DecodedMail decoded;
    try {
      decoded = await decodeMail(envelope);
    } on MailDecodeException catch (error) {
      _rejections.add(RejectedMail(envelope: envelope, reason: error.reason));
      _onLog?.call(
        'permanently rejected undecryptable mail ${envelope.msgId}: '
        '${error.reason}',
      );
      // A permanent cryptographic/shape failure must not redeliver forever.
      upstream.acknowledge(envelope.msgId);
      return;
    } on Object {
      // Secure-store and other transient decode failures leave the original
      // unacked. Never log the thrown value: host errors may contain secrets.
      _onLog?.call(
        'mail decode failed for ${envelope.msgId}; delivery left unacked',
      );
      return;
    }

    // ACL inspection always sees the COMPLETE decrypted wrapper. Its allow
    // result is the only plain text a local sink can observe.
    final decision = sanitizeRemoteWrite(decoded.payload);
    if (decision is AclReject) {
      _rejections.add(
        RejectedMail(envelope: envelope, reason: decision.reason),
      );
      _onLog?.call('ACL rejected mail ${envelope.msgId}: ${decision.reason}');
      // Acked: refused content must not loop via redelivery (§6 AC6).
      upstream.acknowledge(envelope.msgId);
      return;
    }
    final mail = InboundMail(
      envelope: envelope,
      text: (decision as AclAllow).text,
      sessionId: decoded.sessionId,
      senderPubkey: decoded.senderPubkey,
      threaded: decoded.threaded,
    );
    try {
      await sink(mail);
    } on Object catch (error) {
      // No ack — the server redelivers (§3: no lost input).
      _onLog?.call('sink write failed for ${envelope.msgId}: $error');
      return;
    }
    _dmMail.add(mail);
    upstream.acknowledge(envelope.msgId);
  }

  void _handleFrame(NetworkEnvelope envelope) {
    switch (envelope.kind) {
      case NetworkEnvelopeKind.mail:
        _handleMail(envelope);
      case NetworkEnvelopeKind.roster:
        _rosterFrames.add(envelope);
      case NetworkEnvelopeKind.presence:
        _presenceFrames.add(envelope);
      case NetworkEnvelopeKind.wakeHint:
        _wakeHints.add(envelope);
      case NetworkEnvelopeKind.error:
        _onLog?.call(
          'server error for ${envelope.refId ?? '?'}: '
          '${envelope.payload['message'] ?? ''}',
        );
      case NetworkEnvelopeKind.ack:
      case NetworkEnvelopeKind.hello:
      case NetworkEnvelopeKind.helloOk:
      case NetworkEnvelopeKind.ping:
      case NetworkEnvelopeKind.pong:
        break;
    }
  }

  /// Demuxes one inbound mail frame; unrouted addresses are refused by
  /// an error frame referencing the mail (§3) so the server stops
  /// redelivering payloads no local sink owns.
  void _handleMail(NetworkEnvelope envelope) {
    final outcome = mux.demux(envelope);
    if (outcome != DemuxOutcome.unrouted) return;
    unawaited(
      upstream
          .send(
            NetworkEnvelope(
              kind: NetworkEnvelopeKind.error,
              msgId: idFactory(),
              refId: envelope.msgId,
              ts: rfc3339Timestamp(DateTime.now().toUtc()),
              payload: {
                'message':
                    'no local sink for ${envelope.to ?? envelope.channel}',
              },
            ),
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> _publishPresence(PresenceFrame frame) async {
    try {
      await upstream.send(frame.toEnvelope(idFactory: idFactory));
    } on ConnectorOfflineException {
      // Presence is periodic — the next heartbeat carries it (§5).
    } on Object catch (error) {
      _onLog?.call('presence publish failed: $error');
    }
  }

  Future<void> _drainOutbox() async {
    if (_draining) return;
    _draining = true;
    try {
      await drainOutbox(
        outbox,
        (entry) => upstream.send(entry.envelope),
        canSend: () => upstream.isReady,
      );
    } finally {
      _draining = false;
    }
  }

  Future<void> _refreshLeases() async {
    if (_liveLeasesSync != null) {
      _leaseCache = _liveLeasesSync();
      return;
    }
    final delegate = leases;
    if (delegate == null) return;
    try {
      _leaseCache = await delegate();
    } on Object catch (error) {
      _onLog?.call('lease refresh failed: $error');
    }
  }

  /// Exposed session ids across every configured network — the presence
  /// frame's session surface (§5/§6, exposed entries only).
  Set<String> _exposedSessionIds() {
    final ids = <String>{};
    for (final network in registry.networkIds) {
      for (final agent in registry.rosterProjection(network).agents) {
        ids.addAll(agent.sessions);
      }
    }
    return ids;
  }

  /// Closes the connector's streams (after [stop]).
  void dispose() {
    _rejections.close();
    _rosterFrames.close();
    _presenceFrames.close();
    _wakeHints.close();
    _dmMail.close();
    mux.dispose();
  }
}
