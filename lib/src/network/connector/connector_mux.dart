/// The envelope mux/demux of the machine connector (contract
/// `docs/fa_network_connector.md` §3): inbound mail routed by
/// `(network, channel, to)` to registered local sinks, `msgId` dedup with a
/// bounded window, per-route FIFO handler ordering that survives
/// reconnects, and an ordered outbound send queue.
///
/// Rules encoded from §3:
/// - the server routes mail by `(network, channel, to)` — the local demux
///   mirrors that keying exactly (AC2 isolation);
/// - at-least-once delivery upstream of the ack means duplicate `msgId`s
///   arrive after reconnects — the windowed dedup collapses them so sinks
///   see each mail once;
/// - per-sender order is preserved: handlers chain per route, the dedup
///   window is never reset on reconnect, and the outbound queue keeps
///   insertion order across attach/detach cycles.
///
/// Pure Dart: no `dart:io`, no Flutter.
library;

import 'dart:async';
import 'dart:collection';

import 'envelope.dart';

/// The routing key of one sink (contract §3): mail is demuxed by
/// `(network, channel, to)`. An empty [to] registers the CHANNEL catch-all
/// sink — it receives any mail on that channel when no exact-address sink
/// claimed it.
final class MailRoute {
  /// Registers a sink for [network]/[channel], optionally narrowed to one
  /// recipient address.
  const MailRoute({required this.network, required this.channel, this.to = ''});

  /// The network id.
  final String network;

  /// The channel id (group channel or `dm:...` virtual channel).
  final String channel;

  /// The exact recipient address (`<agent>@<device>` / `user:<id>`) or ''
  /// for the channel catch-all.
  final String to;

  @override
  bool operator ==(Object other) =>
      other is MailRoute &&
      other.network == network &&
      other.channel == channel &&
      other.to == to;

  @override
  int get hashCode => Object.hash(network, channel, to);

  @override
  String toString() =>
      'MailRoute($network/$channel${to.isEmpty ? '' : '/$to'})';
}

/// A local sink: the async handler one mail frame is written to. The mux
/// awaits the previous handler on the same route before invoking the next
/// one — per-route FIFO (contract §3 preserves per-sender order).
typedef MailSink = Future<void> Function(NetworkEnvelope envelope);

/// The ordered outbound sender attached via [ConnectorMux.attachOutbound].
typedef OutboundSender = Future<void> Function(NetworkEnvelope envelope);

/// What [ConnectorMux.demux] did with a frame.
enum DemuxOutcome {
  /// Matched a sink; the handler chain will run it (FIFO per route).
  delivered,

  /// The `msgId` was already seen inside the dedup window — collapsed.
  duplicate,

  /// No sink claims this `(network, channel, to)`; the frame was reported
  /// to the mux's `onUnrouted` hook.
  unrouted,

  /// The frame violates the §3 per-kind rules; reported to `onInvalid`.
  invalid,
}

/// Handle returned by [ConnectorMux.registerSink]; close it to detach the
/// sink (idempotent).
final class SinkRegistration {
  SinkRegistration._(this._mux, this._route, this._sink);

  final ConnectorMux _mux;
  final MailRoute _route;
  final MailSink _sink;
  bool _closed = false;

  /// Detaches the sink. Pending handlers already queued still run.
  void close() {
    if (_closed) return;
    _closed = true;
    _mux._removeSink(_route, _sink);
  }
}

/// The envelope mux (contract §3 demux + ordered outbound queue).
///
/// Inbound: [demux] validates, dedups by `msgId` (bounded, configurable
/// window — the SAME id that is the fanet1 frameId, contract v1.1) and
/// chains the matched sink per route. The window is never reset — dedup and
/// per-route ordering survive reconnects (AC2).
///
/// Outbound: [send] enqueues; the frames flush through the attached
/// [OutboundSender] strictly in insertion order. While no sender is
/// attached (upstream down) frames wait at the queue head; a sender failure
/// detaches and leaves the failed frame queued at the front — order never
/// reshuffles. [takePending] hands the queue out (used to spill into the
/// durable offline outbox).
final class ConnectorMux {
  /// Builds a mux. [dedupWindow] bounds the seen-`msgId` ring (at-least-once
  /// redeliveries are recent; 4096 ids is generous). `onUnrouted` and
  /// `onInvalid` receive diagnostics for frames no sink claimed or frames
  /// failing §3 validation.
  ConnectorMux({
    this.dedupWindow = defaultDedupWindow,
    this.onUnrouted,
    this.onInvalid,
    this.onOutboundError,
  });

  /// The default dedup window size.
  static const int defaultDedupWindow = 4096;

  /// Bounded window of recently seen `msgId`s.
  final int dedupWindow;

  /// Diagnostics hook for mail no sink claims.
  void Function(NetworkEnvelope envelope)? onUnrouted;

  /// Diagnostics hook for frames failing §3 validation.
  void Function(NetworkEnvelope envelope, List<String> problems)? onInvalid;

  /// Diagnostics hook for outbound sender failures (the failed frame stays
  /// queued at the head).
  void Function(NetworkEnvelope envelope, Object error)? onOutboundError;

  final _sinks = <MailRoute, List<MailSink>>{};
  final _routeTails = <String, Future<void>>{};
  final _seen = SplayTreeSet<String>((a, b) => a.compareTo(b));
  final _seenOrder = Queue<String>();
  final _outbound = Queue<NetworkEnvelope>();
  final _pumpDone = <Completer<void>>{};
  OutboundSender? _sender;
  Future<void>? _activePump;
  bool _pumping = false;

  /// Registers [sink] for [route]; multiple sinks per route fan the frame
  /// out to all of them in registration order. Returns a [SinkRegistration]
  /// to detach with.
  SinkRegistration registerSink(MailRoute route, MailSink sink) {
    (_sinks[route] ??= []).add(sink);
    return SinkRegistration._(this, route, sink);
  }

  void _removeSink(MailRoute route, MailSink sink) {
    final sinks = _sinks[route];
    if (sinks == null) return;
    sinks.remove(sink);
    if (sinks.isEmpty) _sinks.remove(route);
  }

  /// Whether [msgId] was seen inside the dedup window (test seam).
  bool hasSeen(String msgId) => _seen.contains(msgId);

  /// Demuxes one inbound frame (contract §3): validate → dedup → route.
  /// Validation runs BEFORE the dedup window so malformed frames never
  /// consume ids. Handlers chain per route (FIFO); [demux] returns once the
  /// frame is queued for its sinks, not after the sinks ran — await
  /// [settle] for the handlers to finish.
  DemuxOutcome demux(NetworkEnvelope envelope) {
    if (envelope.kind != NetworkEnvelopeKind.mail) {
      return DemuxOutcome.invalid;
    }
    final problems = envelope.validationErrors;
    if (problems.isNotEmpty) {
      onInvalid?.call(envelope, problems);
      return DemuxOutcome.invalid;
    }
    if (!_remember(envelope.msgId)) {
      return DemuxOutcome.duplicate;
    }
    final sinks = _sinksFor(envelope);
    if (sinks.isEmpty) {
      onUnrouted?.call(envelope);
      return DemuxOutcome.unrouted;
    }
    for (final sink in sinks) {
      _chain(envelope, sink);
    }
    return DemuxOutcome.delivered;
  }

  bool _remember(String msgId) {
    if (!_seen.add(msgId)) return false;
    _seenOrder.addLast(msgId);
    while (_seenOrder.length > dedupWindow) {
      _seen.remove(_seenOrder.removeFirst());
    }
    return true;
  }

  List<MailSink> _sinksFor(NetworkEnvelope envelope) {
    final exact =
        _sinks[MailRoute(
          network: envelope.network ?? '',
          channel: envelope.channel ?? '',
          to: envelope.to ?? '',
        )] ??
        const <MailSink>[];
    if (exact.isNotEmpty) return exact;
    return _sinks[MailRoute(
          network: envelope.network ?? '',
          channel: envelope.channel ?? '',
        )] ??
        const <MailSink>[];
  }

  void _chain(NetworkEnvelope envelope, MailSink sink) {
    final key = '${envelope.network}/${envelope.channel}/${envelope.to}';
    final previous = _routeTails[key] ?? Future<void>.value();
    final tail = previous
        .then((_) => sink(envelope))
        // A throwing sink must not poison the chain: later frames still run.
        .catchError((Object _) {});
    _routeTails[key] = tail;
    _trackSettle(tail);
  }

  void _trackSettle(Future<void> tail) {
    _pumpDone.add(Completer<void>()..complete(tail));
  }

  /// Resolves when every queued sink handler has settled and the outbound
  /// pump is idle (test seam for deterministic assertions).
  Future<void> settle() async {
    while (true) {
      final pump = _activePump;
      if (pump != null) {
        await pump;
        if (!identical(pump, _activePump)) continue;
      }
      final tails = _pumpDone.isEmpty
          ? const <Future<void>>[]
          : List<Future<void>>.of(
              _pumpDone.map((completer) => completer.future),
            );
      _pumpDone.clear();
      if (tails.isEmpty && identical(pump, _activePump)) break;
      await Future.wait<void>(tails);
    }
  }

  /// Attaches the ordered outbound sender; any queued frames flush
  /// immediately in insertion order.
  void attachOutbound(OutboundSender sender) {
    _sender = sender;
    _pump();
  }

  /// Detaches the outbound sender; queued frames stay in place. Idempotent.
  void detachOutbound() {
    _sender = null;
  }

  /// Whether an outbound sender is attached.
  bool get isOutboundAttached => _sender != null;

  /// Frames waiting in the outbound queue.
  int get pendingOutbound => _outbound.length;

  /// Enqueues [envelope] on the ordered outbound queue (insertion order is
  /// the send order — contract §3 preserves per-sender order) and kicks the
  /// pump when a sender is attached.
  void send(NetworkEnvelope envelope) {
    _outbound.addLast(envelope);
    _pump();
  }

  void _pump() {
    if (_pumping) return;
    final sender = _sender;
    if (sender == null) return;
    _pumping = true;
    final done = Completer<void>();
    _activePump = done.future;
    Future<void>(() async {
      while (_outbound.isNotEmpty && identical(_sender, sender)) {
        final head = _outbound.first;
        try {
          await sender(head);
        } on Object catch (error) {
          // Keep the failed frame at the head — order never reshuffles;
          // detach so later sends queue up instead of hammering.
          _sender = null;
          onOutboundError?.call(head, error);
          return;
        }
        _outbound.removeFirst();
      }
    }).whenComplete(() {
      if (identical(done.future, _activePump)) _activePump = null;
      _pumping = false;
      done.complete();
      if (_sender != null && _outbound.isNotEmpty) _pump();
    });
  }

  /// Hands out and clears every queued outbound frame, preserving order
  /// (used to spill the queue into the durable offline outbox when the
  /// upstream goes down).
  List<NetworkEnvelope> takePending() {
    final frames = List<NetworkEnvelope>.of(_outbound);
    _outbound.clear();
    return frames;
  }

  /// Detaches and drops pending state; sinks and dedup history are cleared.
  void dispose() {
    detachOutbound();
    _outbound.clear();
    _sinks.clear();
    _seen.clear();
    _seenOrder.clear();
    _routeTails.clear();
  }
}
