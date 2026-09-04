// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The host-side producer behind `FaChatService.trajectory`.
///
/// Wraps a core [TrajectorySnapshotBuilder] and exposes its snapshots as a
/// broadcast stream: hosts feed session records ([append]), mirror the live
/// tail ([applyEvent]), and rebuild on session open/switch ([reset] plus
/// appends); the chat's timeline panel subscribes to [stream]. Every
/// listener first receives [latest], so a panel opened mid-session renders
/// immediately instead of flashing its loading state.
final class TrajectoryServiceFeed {
  final TrajectorySnapshotBuilder _builder = TrajectorySnapshotBuilder();
  final _changes = StreamController<TrajectorySnapshot>.broadcast(sync: true);
  TrajectorySnapshot _latest = TrajectorySnapshot.empty;

  /// The most recent snapshot, regardless of listeners.
  TrajectorySnapshot get latest => _latest;

  /// Broadcast stream of snapshots; replays [latest] to every new listener.
  Stream<TrajectorySnapshot> get stream => Stream.multi((listener) {
    listener.add(_latest);
    final subscription = _changes.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    listener.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Projects a finalized session record and emits the new snapshot.
  TrajectorySnapshot append(SessionRecord record) =>
      _emit(_builder.append(record));

  /// Projects a streaming agent event and emits the new snapshot.
  TrajectorySnapshot applyEvent(AgentEvent event) =>
      _emit(_builder.applyEvent(event));

  /// Clears all projected state and emits the empty snapshot.
  void reset() {
    _builder.reset();
    _emit(_builder.build());
  }

  /// Releases the stream; the feed is unusable afterwards.
  void dispose() {
    _changes.close();
  }

  TrajectorySnapshot _emit(TrajectorySnapshot snapshot) {
    _latest = snapshot;
    _changes.add(snapshot);
    return snapshot;
  }
}
