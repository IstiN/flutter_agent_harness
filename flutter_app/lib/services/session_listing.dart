import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Newest-first listing order: last-updated descending, creation time
/// descending as the tiebreak — the order both hosts' session lists are
/// stable across re-lists.
int compareSessionsNewestFirst(SessionMetadata a, SessionMetadata b) {
  final aTime = a.lastUpdatedAt ?? a.createdAt;
  final bTime = b.lastUpdatedAt ?? b.createdAt;
  final result = bTime.compareTo(aTime);
  if (result != 0) return result;
  return b.createdAt.compareTo(a.createdAt);
}

/// Merges per-root session listings into one id-deduplicated
/// newest-first list. A [listRoot] failure is non-fatal — a broken
/// secondary root must not break the listing (the shared multi-root rule
/// of the app service and the session manager).
Future<List<SessionMetadata>> mergeSessionsAcrossRoots({
  required Iterable<String> roots,
  required Future<List<SessionMetadata>> Function(String root) listRoot,
}) async {
  final seen = <String>{};
  final merged = <SessionMetadata>[];
  for (final root in roots) {
    try {
      for (final item in await listRoot(root)) {
        if (seen.add(item.id)) {
          merged.add(item);
        }
      }
    } on Object {
      // Secondary root list failure is non-fatal.
    }
  }
  return merged..sort(compareSessionsNewestFirst);
}
