/// In-process Dart transport adapters for the Agent Wire Protocol
/// (issue #1101 slice 1) — the DEFAULT transport when the host IS
/// Dart/Flutter.
///
/// [toWire] turns the engine's [AgentEvent] stream into wire frames;
/// [fromWire] turns received frames back into decoded events. No sockets,
/// no isolate plumbing: streams in, streams out. A foreign-language host
/// wraps the same frames in its own transport (NDJSON framing rules in
/// `docs/wire-protocol.md`).
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';

import 'wire_protocol.dart';

/// Maps a live [AgentEvent] stream onto the wire. Unknown event kinds
/// cannot occur here — the engine only emits native events.
Stream<Map<String, dynamic>> toWire(
  Stream<AgentEvent> events, {
  AgentWireProtocol? protocol,
}) {
  final wire = protocol ?? AgentWireProtocol();
  return events.map(wire.encodeEvent);
}

/// Decodes a received frame stream. Every frame yields one
/// [DecodedWireEvent]: [KnownWireEvent] for native events,
/// [RequestWireEvent] for host-interaction requests, [UnknownWireEvent]
/// for unknown kinds (the passthrough keeps the stream alive, E3).
Stream<DecodedWireEvent> fromWire(
  Stream<Map<String, dynamic>> frames, {
  AgentWireProtocol? protocol,
}) {
  final wire = protocol ?? AgentWireProtocol();
  return frames.map(wire.decodeEvent);
}
