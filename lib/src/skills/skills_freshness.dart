/// Skills discovery freshness (gh-1440): a stat-level fingerprint of the
/// skill-root directories.
///
/// The discovered-skills index is a cache, not truth: a skill that lands on
/// disk mid-session must become visible without a restart. The freshness
/// check compares this fingerprint (one directory listing per skill root —
/// entry names, kinds, sizes and mtimes, never file bodies) against the
/// value recorded at the last discovery scan; a difference means the scan
/// is stale and the host re-runs `discoverSkills` (same roots, same consent
/// gate, same toggles). An unchanged fingerprint costs one `listDir` per
/// root and nothing else.
///
/// Pure Dart: no `dart:io` — the listings come from the [ExecutionEnv]
/// facade, so web/sandbox hosts get the same check for free (E-3).
library;

import '../env/execution_env.dart';
import 'skills.dart';

/// The stamp of a root that does not exist or cannot be listed. Stable by
/// definition — a missing root never triggers a rescan loop (E-4).
const String absentSkillRootStamp = 'absent';

/// One root's stat-level stamp: the directory entries sorted by name, each
/// rendered as `name:kind:size:mtimeMs`. A file edited in place inside a
/// skill subdirectory usually bumps that subdirectory's mtime (and always
/// its own, for flat `<name>.md` skills), so content edits surface here
/// without ever reading content.
String skillRootStamp(List<FileInfo> entries) {
  final sorted = [...entries]..sort((a, b) => a.name.compareTo(b.name));
  return [
    for (final entry in sorted)
      '${entry.name}:${entry.kind.name}:${entry.size}:${entry.mtimeMs}',
  ].join('|');
}

/// The stat-level fingerprint of [roots], in list order. One `listDir` per
/// root; a failed/missing listing maps to [absentSkillRootStamp] (data, not
/// an error — the freshness check never throws on an unreadable root).
///
/// Pass the SAME root list (already consent-filtered) the discovery scan
/// uses, so the fingerprint can only change when the scan's own input
/// changed — third-party roots stay invisible to the check while consent
/// is denied (I3).
final class SkillRootsFingerprint {
  const SkillRootsFingerprint(this.stamps);

  /// Root path → [skillRootStamp] (or [absentSkillRootStamp]).
  final Map<String, String> stamps;

  @override
  bool operator ==(Object other) =>
      other is SkillRootsFingerprint &&
      other.stamps.length == stamps.length &&
      other.stamps.entries.every(
        (entry) => stamps[entry.key] == entry.value,
      );

  @override
  int get hashCode => Object.hashAll(
    [
      for (final key in stamps.keys.toList()..sort())
        Object.hash(key, stamps[key]),
    ],
  );
}

/// Computes the fingerprint of [roots] against [env].
Future<SkillRootsFingerprint> computeSkillRootsFingerprint(
  ExecutionEnv env,
  List<SkillRoot> roots,
) async {
  final stamps = <String, String>{};
  for (final root in roots) {
    final entries = (await env.listDir(root.path)).valueOrNull;
    stamps[root.path] = entries == null
        ? absentSkillRootStamp
        : skillRootStamp(entries);
  }
  return SkillRootsFingerprint(stamps);
}
