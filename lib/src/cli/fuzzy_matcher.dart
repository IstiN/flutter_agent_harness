// Fuzzy substring scorer for the composer autocomplete overlay (issue #275).
//
// Score semantics (oh-my-pi autocomplete.ts style):
// - empty needle matches everything with score 0 (full-list browsing);
// - case-insensitive subsequence match; non-match returns null;
// - higher is better; ties break by shorter text, then lexicographic.
//
// ponytail: single scorer, no alphabet tables; swap in a bounds-pruned DFS
// only if a real dataset shows pathological scoring.
library;

/// One scored candidate: [score], the matched [indices] into the haystack
/// (ascending), and the haystack [text] itself.
class FuzzyMatch implements Comparable<FuzzyMatch> {
  final int score;
  final List<int> indices;
  final String text;

  const FuzzyMatch(this.score, this.indices, this.text);

  @override
  int compareTo(FuzzyMatch other) {
    final byScore = other.score.compareTo(score);
    if (byScore != 0) return byScore;
    final byLength = text.length.compareTo(other.text.length);
    if (byLength != 0) return byLength;
    return text.compareTo(other.text);
  }

  @override
  bool operator ==(Object other) =>
      other is FuzzyMatch &&
      other.score == score &&
      other.text == text &&
      _listEquals(other.indices, indices);

  @override
  int get hashCode => Object.hash(score, text, Object.hashAll(indices));

  @override
  String toString() => 'FuzzyMatch($score, $text)';
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Word-boundary separators: after these the next alphanumerics start a
/// camel/snake/kebab word.
bool _isBoundary(String prev, String ch) {
  if (prev.isEmpty) return true;
  final p = prev.codeUnitAt(0);
  final isSep = p == 0x5F || p == 0x2D || p == 0x20 || p == 0x2F || p == 0x3A;
  final prevLower = p >= 0x61 && p <= 0x7A;
  final chUpper = ch.contains(RegExp(r'[A-Z]'));
  // snake/kebab/space/path separators and camelCase humps are boundaries.
  return isSep || (prevLower && chUpper);
}

/// Greedy left-to-right subsequence match with a boundary-aware score.
/// Returns null when [needle] does not fuzzy-match [haystack].
FuzzyMatch? scoreFuzzy(String haystack, String needle, {int maxIndices = 256}) {
  if (needle.isEmpty) return FuzzyMatch(0, const [], haystack);
  final h = haystack.toLowerCase();
  final n = needle.toLowerCase();
  if (n.length > h.length) return null;

  var hi = 0;
  final indices = <int>[];
  var score = 0;
  var run = 0;
  var prevCh = '';
  for (var ni = 0; ni < n.length; ni++) {
    final want = n[ni];
    var found = -1;
    while (hi < h.length) {
      if (h[hi] == want) {
        found = hi;
        break;
      }
      prevCh = h[hi];
      hi++;
    }
    if (found < 0) return null;
    // Scoring: first char anchor, boundary hits, contiguous-run bonus.
    if (ni == 0) score += 20;
    if (_isBoundary(prevCh, haystack[found])) score += 12;
    if (indices.isNotEmpty && found == indices.last + 1) {
      run += 1;
      score += 4 + run * 2;
    } else {
      run = 0;
    }
    if (found == 0) score += 8; // prefix bonus
    indices.add(found);
    prevCh = haystack[found];
    hi = found + 1;
  }
  // Prefer tight matches: penalize trailing haystack.
  score -= (haystack.length - needle.length).clamp(0, 16);
  if (indices.length > maxIndices) {
    return FuzzyMatch(score, indices.sublist(indices.length - maxIndices), haystack);
  }
  return FuzzyMatch(score, indices, haystack);
}

/// Scores every candidate, drops non-matches, sorts best-first, and caps the
/// result at [limit] so huge path listings stay O(matches) after scoring.
List<FuzzyMatch> rankFuzzy(
  Iterable<String> candidates,
  String needle, {
  int limit = 64,
}) {
  if (needle.isEmpty) {
    return candidates.take(limit).map((t) => FuzzyMatch(0, const [], t)).toList();
  }
  final matches = <FuzzyMatch>[];
  for (final text in candidates) {
    final m = scoreFuzzy(text, needle);
    if (m != null) matches.add(m);
  }
  matches.sort();
  return matches.length > limit ? matches.sublist(0, limit) : matches;
}
