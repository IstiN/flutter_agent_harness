// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime.utc(2026, 1, 1, 12);

  SessionRecord userRecord(String id, {String? parentId}) => MessageRecord(
    id: id,
    parentId: parentId,
    timestamp: at,
    message: UserMessage.text('hello $id'),
  );

  test('a new listener receives the empty snapshot, then emissions', () async {
    final feed = TrajectoryServiceFeed();
    final snapshots = <TrajectorySnapshot>[];
    final subscription = feed.stream.listen(snapshots.add);

    expect(feed.latest.revision, 0);
    feed.append(userRecord('u1'));
    await pumpEventQueue();

    // Replay-on-listen (the empty snapshot) + the append emission.
    expect(snapshots, hasLength(2));
    expect(feed.latest, same(snapshots.last));
    subscription.cancel();
    feed.dispose();
  });

  test('applyEvent mirrors the live tail', () async {
    final feed = TrajectoryServiceFeed();
    final snapshots = <TrajectorySnapshot>[];
    final subscription = feed.stream.listen(snapshots.add);

    feed.applyEvent(MessageStartEvent(UserMessage.text('hi')));
    feed.applyEvent(MessageEndEvent(UserMessage.text('hi')));
    await pumpEventQueue();

    expect(snapshots, hasLength(3)); // replay + two emissions
    expect(snapshots.last.revision, greaterThan(snapshots.first.revision));
    expect(feed.latest, same(snapshots.last));
    subscription.cancel();
    feed.dispose();
  });

  test('reset clears back to the empty snapshot', () async {
    final feed = TrajectoryServiceFeed();
    final snapshots = <TrajectorySnapshot>[];
    final subscription = feed.stream.listen(snapshots.add);
    feed.append(userRecord('u1'));

    feed.reset();
    await pumpEventQueue();

    expect(snapshots, hasLength(3)); // replay + append + reset
    expect(feed.latest.records, isEmpty);
    expect(feed.latest, same(snapshots.last));
    subscription.cancel();
    feed.dispose();
  });

  test('a late listener replays the latest snapshot', () async {
    final feed = TrajectoryServiceFeed();
    feed.append(userRecord('u1'));

    final lateSnapshots = <TrajectorySnapshot>[];
    final subscription = feed.stream.listen(lateSnapshots.add);
    await pumpEventQueue();

    expect(lateSnapshots, [feed.latest]);
    subscription.cancel();
    feed.dispose();
  });
}
