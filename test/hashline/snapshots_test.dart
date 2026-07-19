import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const path = '/w/a.ts';
const other = '/w/b.ts';

void main() {
  group('HashlineSnapshotStore: recording', () {
    test('record derives the tag from whole-file content', () {
      final store = HashlineSnapshotStore();
      const text = 'one\ntwo\n';
      expect(store.record(path, text), computeFileHash(text));
    });

    test('identical re-reads fuse onto one snapshot and union seenLines', () {
      final store = HashlineSnapshotStore();
      const text = 'l1\nl2\nl3\n';
      final first = store.record(path, text, [1]);
      final again = store.record(path, text, [2, 3]);
      expect(again, first);
      final snapshot = store.head(path);
      expect(snapshot, isNotNull);
      expect(snapshot!.seenLines, {1, 2, 3});
      expect(snapshot.recordedAt, greaterThan(0));
    });

    test('new content unshifts a fresh version; head is newest', () {
      final store = HashlineSnapshotStore();
      store.record(path, 'v1\n');
      store.record(path, 'v2\n');
      expect(store.head(path)!.text, 'v2\n');
      expect(store.byContent(path, 'v1\n'), isNotNull);
    });

    test('byHash returns the most recent colliding version', () {
      // These two texts genuinely collide on the 4-hex tag (omp #4075).
      const collideA = 'line one 263\nline two 4471\n';
      const collideB = 'line one 410\nline two 6970\n';
      final store = HashlineSnapshotStore();
      final tagA = store.record(path, collideA, [1]);
      final tagB = store.record(path, collideB, [2]);
      expect(tagA, tagB);
      expect(store.byContent(path, collideA)!.seenLines, {1});
      expect(store.byContent(path, collideB)!.seenLines, {2});
      expect(store.byHash(path, tagA)!.text, collideB);
      expect(store.head(path)!.text, collideB);
    });

    test('recordSeenLines merges into the tagged version', () {
      final store = HashlineSnapshotStore();
      final tag = store.record(path, 'a\nb\n', [1]);
      store.recordSeenLines(path, tag, [2]);
      expect(store.head(path)!.seenLines, {1, 2});
      store.recordSeenLines(path, 'FFFF', [3]); // unknown tag: no-op
      expect(store.head(path)!.seenLines, {1, 2});
    });

    test('record without seenLines leaves provenance absent', () {
      final store = HashlineSnapshotStore();
      store.record(path, 'a\n');
      expect(store.head(path)!.seenLines, isNull);
    });
  });

  group('HashlineSnapshotStore: lookup and maintenance', () {
    test('findByHash spans paths', () {
      final store = HashlineSnapshotStore();
      const text = 'shared\n';
      final tag = store.record(path, text);
      store.record(other, text);
      final matches = store.findByHash(tag);
      expect(matches, hasLength(2));
      expect(matches.every((snapshot) => snapshot.hash == tag), isTrue);
      expect(store.findByHash(tag == '0000' ? 'FFFF' : '0000'), isEmpty);
    });

    test('invalidate drops one path', () {
      final store = HashlineSnapshotStore();
      store.record(path, 'a\n');
      store.record(other, 'b\n');
      store.invalidate(path);
      expect(store.head(path), isNull);
      expect(store.head(other), isNotNull);
    });

    test('relocate moves history and seen-lines provenance', () {
      final store = HashlineSnapshotStore();
      final tag = store.record(path, 'a\nb\n', [1, 2]);
      store.relocate(path, '/w/moved.ts');
      expect(store.head(path), isNull);
      final moved = store.head('/w/moved.ts');
      expect(moved, isNotNull);
      expect(moved!.hash, tag);
      expect(moved.seenLines, {1, 2});
      // Source-tag recovery now finds the moved path.
      expect(store.findByHash(tag).single.path, '/w/moved.ts');
    });

    test('relocate into an existing destination dedups by tag', () {
      final store = HashlineSnapshotStore();
      const text = 'same\n';
      final tag = store.record(path, text);
      store.record(other, text);
      store.relocate(path, other);
      expect(store.byHash(other, tag), isNotNull);
      expect(store.head(path), isNull);
    });

    test('relocate a path without history is a no-op', () {
      final store = HashlineSnapshotStore();
      store.relocate('/w/nope.ts', other);
      expect(store.head(other), isNull);
    });

    test('clear drops everything', () {
      final store = HashlineSnapshotStore();
      store.record(path, 'a\n');
      store.clear();
      expect(store.head(path), isNull);
    });
  });

  group('HashlineSnapshotStore: eviction bounds', () {
    test('per-path history is capped', () {
      final store = HashlineSnapshotStore(maxVersionsPerPath: 2);
      store.record(path, 'v1\n');
      store.record(path, 'v2\n');
      store.record(path, 'v3\n');
      expect(store.byContent(path, 'v1\n'), isNull);
      expect(store.byContent(path, 'v3\n'), isNotNull);
    });

    test('least-recently-used paths age out past maxPaths', () {
      final store = HashlineSnapshotStore(maxPaths: 2);
      store.record('/w/1.ts', 'a\n');
      store.record('/w/2.ts', 'b\n');
      // Touch 1.ts so 2.ts becomes the LRU entry.
      store.record('/w/1.ts', 'a2\n');
      store.record('/w/3.ts', 'c\n');
      expect(store.head('/w/2.ts'), isNull);
      expect(store.head('/w/1.ts'), isNotNull);
      expect(store.head('/w/3.ts'), isNotNull);
    });

    test('total retained text is capped', () {
      final store = HashlineSnapshotStore(maxTotalBytes: 100);
      store.record('/w/1.ts', 'a' * 60);
      store.record('/w/2.ts', 'b' * 60);
      // The first path must have been evicted to stay under the cap.
      expect(store.head('/w/1.ts'), isNull);
      expect(store.head('/w/2.ts'), isNotNull);
    });

    test('re-recording a non-head version promotes it to head', () {
      final store = HashlineSnapshotStore();
      store.record(path, 'v1\n');
      store.record(path, 'v2\n');
      store.record(path, 'v1\n'); // promotes v1 back to head
      expect(store.head(path)!.text, 'v1\n');
      // History still holds both versions exactly once.
      expect(store.byContent(path, 'v2\n'), isNotNull);
    });

    test('relocate caps the merged history at maxVersionsPerPath', () {
      final store = HashlineSnapshotStore(maxVersionsPerPath: 2);
      store.record(path, 'a1\n');
      store.record(path, 'a2\n');
      store.record(other, 'b1\n');
      store.record(other, 'b2\n');
      store.relocate(path, other);
      // Merged history is capped: the two relocated (newest-first) win.
      expect(store.head(other)!.text, 'a2\n');
      expect(store.byContent(other, 'b2\n'), isNull);
    });
  });
}
