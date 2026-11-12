// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/upstream_client.dart';

/// In-memory stand-in for the fa_network device WS server (contract §12):
/// implements the §3–§5 server behavior over the same
/// [ConnectorTransport]/[ConnectorSocket] seams the real connector uses —
/// NO real sockets and NO read-timeouts anywhere (backend field note: a
/// cancelled read closes the connection; quiet waiting is unbounded
/// receive plus the 20 s application ping/pong; half-open drops are the
/// server's job).
///
/// Encoded server rules (§3–§5 + fa_network phase A):
/// - `hello_ok` referencing the hello `msgId`, then the roster snapshot
///   (one frame per seeded network), THEN redelivery of unacked mail in
///   seq order (§4/AC5);
/// - mail validated, deduped by `msgId`, and per-channel `seq`-stamped on
///   persist; the id is NEVER rewritten (contract v1.1);
/// - at-least-once: frames handed to a device socket stay pending until
///   their `ack` arrives; a socket drop (or displacement by a second dial)
///   leaves them queued for the resume redelivery;
/// - a second dial DISPLACES the first socket for the same deviceId (AC1
///   backend behavior);
/// - [connectionCount] is the AC1 "single upstream" assertion helper.
final class FakeDeviceServer {
  /// Builds a fake server; [idFactory] defaults to the system seam, and
  /// [rosterPayloadFor] lets tests customize the snapshot per device.
  FakeDeviceServer({this.rosterPayloadFor, IdFactory? idFactory})
    : _idFactory = idFactory ?? defaultIdFactory;

  /// The roster snapshot payload for a device; the default derives from
  /// [seedDevice] calls (one network entry per seeded network).
  final Map<String, Object?> Function(String deviceId)? rosterPayloadFor;

  final IdFactory _idFactory;
  final _devices = <String, _DeviceRecord>{};
  final _receivedFrames = <NetworkEnvelope>[];
  final _deliveries = <DeliveredMail>[];
  final _persistedFrames = <NetworkEnvelope>[];
  var _connectionCounter = 0;

  /// Soft diagnostics sink (null = drop).
  void Function(String message)? onLog;

  /// Fails the next dial attempts by this count (outage injection, AC5).
  int failNextDials = 0;

  /// Frames received from clients, in arrival order (assertion surface).
  List<NetworkEnvelope> get received => List.unmodifiable(_receivedFrames);

  /// Mail frames handed to a device socket, in handoff order (assertion
  /// surface for redelivery and seq ordering).
  List<DeliveredMail> get deliveries => List.unmodifiable(_deliveries);

  /// Mail frames the server persisted (deduped, seq-stamped) — the
  /// assertion surface for AC2 (isolation, dedup, seq).
  List<NetworkEnvelope> get persistedMail =>
      List.unmodifiable(_persistedFrames);

  /// Total dials accepted — the AC1 counter.
  int get connectionCount => _connectionCounter;

  /// Sockets currently attached (one per device after displacement).
  int get activeConnections =>
      _devices.values.where((record) => record.connection != null).length;

  /// Seeds a device; re-seeding the SAME deviceId is idempotent (backend
  /// phase A: enroll idempotence — same networks returned).
  void seedDevice(
    String deviceId, {
    String? deviceToken,
    List<String> networks = const [],
  }) {
    final record = _devices.putIfAbsent(deviceId, _DeviceRecord.new);
    record.networks
      ..clear()
      ..addAll(networks);
    record.deviceToken = deviceToken;
  }

  /// The transport the connector dials (`wss://fake/ws?ticket=...`).
  ConnectorTransport get transport => _FakeServerTransport(this);

  /// Routes ONE mail frame toward a device (§3 server → device): stamps
  /// the per-channel `seq`, marks it pending, and hands it to the live
  /// socket — or queues it for the resume redelivery when the device is
  /// disconnected. The frame leaves the pending queue only on `ack`.
  void deliverTo({required String deviceId, required NetworkEnvelope mail}) {
    final record = _devices[deviceId];
    if (record == null) {
      onLog?.call('deliverTo: unknown device $deviceId');
      return;
    }
    final stamped = _persist(mail, record);
    final entry = _PendingMail(stamped);
    record.pending[mail.msgId] = entry;
    record.pendingOrder.add(mail.msgId);
    _handOff(record, entry);
  }

  /// Closes every live socket (simulated outage — the AC5 kill switch).
  /// Pending (unacked) frames stay queued for the resume redelivery.
  void dropAll() {
    for (final record in _devices.values) {
      record.detach(drop: true);
    }
  }

  /// The seq the server would stamp next for [deviceId]/[channel] (test
  /// seam for seq-order assertions).
  int nextSeqOf(String deviceId, String channel) =>
      _devices[deviceId]?.nextSeq(channel) ?? 0;

  Map<String, Object?> _rosterPayload(String deviceId) {
    final custom = rosterPayloadFor?.call(deviceId);
    if (custom != null) return custom;
    return {
      'networks': [
        for (final network in _devices[deviceId]?.networks ?? const <String>[])
          {'id': network, 'agents': <Object?>[]},
      ],
    };
  }

  NetworkEnvelope _persist(NetworkEnvelope mail, _DeviceRecord record) {
    final seq = record.nextSeq(mail.channel ?? '');
    return NetworkEnvelope(
      kind: NetworkEnvelopeKind.mail,
      msgId: mail.msgId, // contract v1.1: never rewritten
      network: mail.network,
      channel: mail.channel,
      from: mail.from,
      to: mail.to,
      ts: mail.ts,
      seq: seq,
      ciphertext: mail.ciphertext,
    );
  }

  void _handOff(_DeviceRecord record, _PendingMail entry) {
    final connection = record.connection;
    if (connection == null || !connection.isOpen) return;
    _deliveries.add(
      DeliveredMail(msgId: entry.envelope.msgId, seq: entry.envelope.seq ?? 0),
    );
    connection.pushToClient(entry.envelope);
  }

  Future<void> _onClientFrame(
    _FakeConnection connection,
    NetworkEnvelope envelope,
  ) async {
    _receivedFrames.add(envelope);
    switch (envelope.kind) {
      case NetworkEnvelopeKind.hello:
        await _onHello(connection, envelope);
      case NetworkEnvelopeKind.mail:
        await _onClientMail(connection, envelope);
      case NetworkEnvelopeKind.ack:
        connection.record?.pending.remove(envelope.refId);
      case NetworkEnvelopeKind.ping:
        final record = connection.record;
        if (record != null && connection.isOpen) {
          connection.pushToClient(
            NetworkEnvelope(
              kind: NetworkEnvelopeKind.pong,
              msgId: _idFactory(),
              refId: envelope.msgId,
              ts: rfc3339Timestamp(DateTime.now().toUtc()),
            ),
          );
        }
      default:
        break;
    }
  }

  Future<void> _onHello(
    _FakeConnection connection,
    NetworkEnvelope hello,
  ) async {
    final deviceId = '${hello.payload['deviceId'] ?? ''}';
    if (deviceId.isEmpty) {
      await _sendError(connection, hello, 'hello requires payload deviceId');
      return;
    }
    final record = _devices[deviceId] ?? (_devices[deviceId] = _DeviceRecord());
    connection.record = record;
    // Displacement: a second dial replaces the first socket for the same
    // device (AC1 backend behavior) — the old one is closed; its unacked
    // mail stays pending for the new connection's redelivery.
    record.detach(drop: true);
    record.connection = connection;
    await connection.pushToClient(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.helloOk,
        msgId: _idFactory(),
        refId: hello.msgId,
        ts: rfc3339Timestamp(DateTime.now().toUtc()),
      ),
    );
    // Roster snapshot: one frame per seeded network (phase A).
    for (final network in record.networks) {
      await connection.pushToClient(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.roster,
          msgId: _idFactory(),
          network: network,
          ts: rfc3339Timestamp(DateTime.now().toUtc()),
          payload: _rosterPayload(deviceId),
        ),
      );
    }
    // THEN redelivery of unacked mail in seq order (§4/AC5).
    final due = [
      for (final msgId in record.pendingOrder)
        if (record.pending[msgId] != null) record.pending[msgId]!,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    for (final entry in due) {
      _handOff(record, entry);
    }
  }

  Future<void> _onClientMail(
    _FakeConnection connection,
    NetworkEnvelope mail,
  ) async {
    final problems = mail.validationErrors;
    if (problems.isNotEmpty) {
      await _sendError(
        connection,
        mail,
        'invalid mail: ${problems.join('; ')}',
      );
      return;
    }
    final record = connection.record;
    if (record == null) {
      await _sendError(connection, mail, 'mail before hello');
      return;
    }
    // Server-side msgId dedup — at-least-once upstream of the ack (§3).
    if (!record.seenMsgIds.add(mail.msgId)) {
      onLog?.call('duplicate msgId dropped server-side: ${mail.msgId}');
      return;
    }
    _persistedFrames.add(_persist(mail, record));
  }

  Future<void> _sendError(
    _FakeConnection connection,
    NetworkEnvelope about,
    String message,
  ) async {
    if (!connection.isOpen) return;
    await connection.pushToClient(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.error,
        msgId: _idFactory(),
        refId: about.msgId,
        ts: rfc3339Timestamp(DateTime.now().toUtc()),
        payload: {'message': message},
      ),
    );
  }
}

/// One mail frame handed to a device socket (assertion helper).
final class DeliveredMail {
  const DeliveredMail({required this.msgId, required this.seq});

  /// The delivered frame id (never rewritten — contract v1.1).
  final String msgId;

  /// The server-stamped sequence number.
  final int seq;

  @override
  String toString() => 'DeliveredMail($msgId seq=$seq)';
}

/// One device's server-side state.
final class _DeviceRecord {
  String? deviceToken;
  final networks = <String>[];
  final seenMsgIds = <String>{};
  final pending = <String, _PendingMail>{};
  final pendingOrder = Queue<String>();
  final _seqCounters = <String, int>{};
  _FakeConnection? connection;

  int nextSeq(String channel) =>
      _seqCounters[channel] = (_seqCounters[channel] ?? 0) + 1;

  void detach({required bool drop}) {
    final connection = this.connection;
    if (connection == null) return;
    this.connection = null;
    if (drop) connection.closeFromServer();
  }
}

final class _PendingMail {
  const _PendingMail(this.envelope);
  final NetworkEnvelope envelope;
  int get seq => envelope.seq ?? 0;
}

/// One accepted dial: the client-facing socket plus the server-side
/// dispatch context (device record bound on hello).
final class _FakeConnection {
  _FakeConnection(this._server) {
    client = _PairedClientSocket(this);
  }

  final FakeDeviceServer _server;
  late final _PairedClientSocket client;
  _DeviceRecord? record;

  bool get isOpen => client.isOpen;

  Future<void> pushToClient(NetworkEnvelope envelope) =>
      client.deliver(envelope);

  void closeFromServer() => client.drop();

  Future<void> handleClientFrame(NetworkEnvelope envelope) =>
      _server._onClientFrame(this, envelope);
}

final class _PairedClientSocket implements ConnectorSocket {
  _PairedClientSocket(this._connection);

  final _FakeConnection _connection;
  final _frames = StreamController<NetworkEnvelope>.broadcast();
  var _closed = false;

  @override
  Stream<NetworkEnvelope> get frames => _frames.stream;

  @override
  bool get isOpen => !_closed;

  @override
  Future<void> send(NetworkEnvelope envelope) async {
    if (_closed) throw StateError('socket closed');
    await _connection.handleClientFrame(envelope);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final record = _connection.record;
    if (record?.connection == _connection) {
      record!.connection = null;
    }
    await _frames.close();
  }

  Future<void> deliver(NetworkEnvelope envelope) async {
    if (_closed) return;
    _frames.add(envelope);
  }

  /// Server-side close (displacement or outage): the client sees its
  /// frames stream end and reconnects.
  void drop() {
    if (_closed) return;
    _closed = true;
    _frames.close();
  }
}

final class _FakeServerTransport implements ConnectorTransport {
  _FakeServerTransport(this._server);

  final FakeDeviceServer _server;

  @override
  Future<ConnectorSocket> dial(Uri url, String ticket) async {
    if (_server.failNextDials > 0) {
      _server.failNextDials--;
      throw StateError('server unreachable (injected outage)');
    }
    _server._connectionCounter++;
    return _FakeConnection(_server).client;
  }
}
