/// Stale/near-miss background-job id resolution (gh-1438).
///
/// Production monitor sessions re-polled job ids reconstructed from memory:
/// the `sh-NNN-` numeric part right, the hash suffix wrong. Every poll hit
/// the registry's exact-match lookup and dead-ended with a bare
/// `unknown background job` error. The pure helpers here classify a
/// requested id against the retained ids so the `bash_job` tool can resolve
/// a unique near-miss, name ambiguity instead of silently picking, and
/// suggest the closest retained ids otherwise.
///
/// Everything is pure: the registry (lib/src/tools/shell_jobs.dart) feeds
/// retained ids in and maps the match back onto its entries.
library;

import 'dart:math';

/// The `sh-<n>-<tail>` shape every [newShellJobId] mints: `sh-`, the
/// per-registry counter, a dash, then the base36 microsecond+random tail.
///
/// A bare `sh-99` (the pre-unique-id short scheme) has no tail part and is
/// NOT this shape — reconstruction from memory always keeps a (wrong)
/// suffix, so a tailless id carries no resolvable information.
final class ShellJobIdParts {
  const ShellJobIdParts({required this.n, required this.tail});

  /// The per-registry counter part (`sh-<n>-`).
  final int n;

  /// The hash suffix after the counter dash.
  final String tail;
}

/// Parses [id] as the minted job-id shape, or null when it does not have
/// it (edge case E3 — resolution is skipped for such ids).
ShellJobIdParts? parseShellJobIdParts(String id) {
  final match = _jobIdShape.firstMatch(id);
  if (match == null) return null;
  final n = int.tryParse(match.group(1)!);
  if (n == null) return null;
  final tail = match.group(2)!;
  if (tail.isEmpty) return null;
  return ShellJobIdParts(n: n, tail: tail);
}

final RegExp _jobIdShape = RegExp(r'^sh-(\d*)-(.*)$');

/// How close [candidate] is to [requested] — lower is closer. Ids sharing
/// the numeric part (the part memory gets right) always rank ahead of ids
/// that don't; within one numeric part the edit distance of the tail
/// decides.
int shellJobIdCloseness(String requested, String candidate) {
  final a = parseShellJobIdParts(requested);
  final b = parseShellJobIdParts(candidate);
  if (a == null || b == null || a.n != b.n) {
    return _differentNumericPenalty + _editDistance(requested, candidate);
  }
  return _editDistance(a.tail, b.tail);
}

const _differentNumericPenalty = 1 << 20;

/// The retained ids closest to [requested], closest first, at most [limit].
/// Ties break by id so the order is deterministic.
List<String> closestShellJobIds(
  String requested,
  Iterable<String> retainedIds, {
  int limit = 3,
}) {
  final ranked = retainedIds.toList()
    ..sort((a, b) {
      final byCloseness = shellJobIdCloseness(
        requested,
        a,
      ).compareTo(shellJobIdCloseness(requested, b));
      return byCloseness != 0 ? byCloseness : a.compareTo(b);
    });
  if (ranked.length > limit) return ranked.sublist(0, limit);
  return ranked;
}

/// Levenshtein edit distance, bounded by the id lengths (double-row DP).
int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    current[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final substitution =
          previous[j] + (a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1);
      current[j + 1] = [
        previous[j + 1] + 1,
        current[j] + 1,
        substitution,
      ].reduce(min);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// The classification of a requested (possibly stale) job id against the
/// retained ids. Pure — the registry resolves matches back onto entries.
sealed class ShellJobIdMatch {
  const ShellJobIdMatch();
}

/// Exactly one retained id shares the requested numeric part (an exact
/// match resolves as this too).
final class ShellJobIdUnique extends ShellJobIdMatch {
  const ShellJobIdUnique(this.id);

  /// The retained id to resolve to.
  final String id;
}

/// Two or more retained ids share the numeric part (edge case E1) — no
/// silent pick; the caller lists the candidates instead. Bounded at 3.
final class ShellJobIdAmbiguous extends ShellJobIdMatch {
  const ShellJobIdAmbiguous(this.ids);

  /// The candidate ids, id-sorted, at most 3.
  final List<String> ids;
}

/// No retained id shares the numeric part — or the requested id is
/// malformed (edge case E3, [closest] empty: resolution skipped).
final class ShellJobIdNoMatch extends ShellJobIdMatch {
  const ShellJobIdNoMatch(this.closest);

  /// Up to 3 nearest retained ids ([] for malformed ids and empty
  /// registries).
  final List<String> closest;
}

/// Classifies [requested] against [retainedIds] (gh-1438): unique same-`n`
/// match resolves, 2+ stay ambiguous, none falls back to the closest ids.
ShellJobIdMatch matchShellJobId(
  String requested,
  Iterable<String> retainedIds,
) {
  final parts = parseShellJobIdParts(requested);
  // Edge case E3: without the minted shape there is nothing to resolve on.
  if (parts == null) return const ShellJobIdNoMatch([]);
  final sameN = [
    for (final id in retainedIds)
      if (parseShellJobIdParts(id)?.n == parts.n) id,
  ]..sort();
  if (sameN.length == 1) return ShellJobIdUnique(sameN.single);
  if (sameN.length > 1) return ShellJobIdAmbiguous(sameN.take(3).toList());
  return ShellJobIdNoMatch(closestShellJobIds(requested, retainedIds));
}

/// Compact "how long ago" wording for a settled job (`45s ago`, `3m ago`,
/// `2h ago`, `2d ago`; sub-second = `just now`). Pure — callers pass the
/// elapsed duration so tests stay deterministic.
String shellJobSettledAgo(Duration elapsed) {
  if (elapsed.inSeconds < 1) return 'just now';
  if (elapsed.inSeconds < 60) return '${elapsed.inSeconds}s ago';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  return '${elapsed.inDays}d ago';
}
