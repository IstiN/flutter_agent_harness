/// Volatile-field scrubbing + structural extraction for the omp REG parity
/// suite (issue #810, S7).
///
/// The committed omp reference twins under
/// `test/integration/screenshots/omp_ref/` and the live fa renders describe
/// the SAME scripted scenarios, but fa's model id, cwd, wall-clock time,
/// token totals and cost differ from omp's by definition. The parity diff is
/// therefore SHAPE-not-bytes: this library scrubs every volatile value to a
/// placeholder, splits the status bar on separator glyphs into segment
/// tokens, and compares the resulting signatures.
///
/// Pure string math — no IO, no clock — so the normalizer is unit-testable
/// in plain `dart test` (issue #810's only unit-test surface).
///
/// MUST STAY FLUTTER-FREE: this lives in the root package's `lib/src/cli/`
/// and is imported by the plain-dart root REG suite (`test/cli/`) and by
/// the flutter_app visual legs via `package:flutter_agent_harness/...` —
/// any flutter import here breaks the root suite, and no cross-package
/// relative import survives static gates on a main checkout (issue #810).
library;

/// Separator glyphs the status bar may use, by preset separator style
/// (omp `separators.ts`; fa `StatusLineSeparatorStyle`).
const Map<String, String> kRegSeparatorGlyphs = {
  'powerline-thin': '\u{E0B2}',
  'powerline-thick': '\u{E0B0}',
  'plain': ' ',
};

/// The volatile values scrubbed before two twins are compared, as
/// (pattern, placeholder) pairs applied in order. Longer, more specific
/// patterns come first so e.g. a cost is not partially eaten by the generic
/// number rule.
final List<(Pattern, String)> kVolatilePatterns = [
  // Elapsed / clock forms first: "3d 4h 12m", "1h 05m", "4m 30s", "12s",
  // "840ms" — the generic number rule would shred these.
  (RegExp(r'\b\d+d \d+h \d+m\b'), '<time>'),
  (RegExp(r'\b\d+h \d+m\b'), '<time>'),
  (RegExp(r'\b\d+m \d+s\b'), '<time>'),
  (RegExp(r'\b\d+(?:\.\d+)?ms\b'), '<time>'),
  (RegExp(r'\b\d+(?:\.\d+)?s\b'), '<time>'),
  // Cost before the generic number rule: "$12.34", and the bracketed
  // spend form "[ $0.00 ]" the shared cost segment paints.
  (RegExp(r'\[\$\d+\.\d{2}\]'), '<cost>'),
  (RegExp(r'\$\d+\.\d{2}'), '<cost>'),
  // Token counts: the VALUE scrubs, the unit stays ('<tok> tok',
  // '<tok> tok/s') — the unit is the structural trace of the segment.
  (RegExp(r'\b\d+(?:,\d{3})*(?:\.\d+)?k?(?= tok)'), '<tok>'),
  // Paths BEFORE the generic numeric rules: any path containing a
  // standalone digit segment ("/logs/2024/run") must be claimed whole by
  // this rule, not shredded into `<path><num><path>` (issue #810 review).
  // The pattern is anchored on path starts ("~", ".", "/"), so it cannot
  // eat numbers inside plain words.
  (RegExp(r'(?:~|\.)?/[A-Za-z0-9._@/-]{2,}'), '<path>'),
  // Numbers with thousands separators next ("1,234"), then k-suffixed
  // magnitudes ("12.3k"), then the context gauge percent ("23%"), then
  // bare numbers.
  (RegExp(r'\b\d+(?:,\d{3})+\b'), '<num>'),
  (RegExp(r'\b\d+(?:\.\d+)?k\b'), '<num>'),
  (RegExp(r'\b\d+%'), '<pct>%'),
  (RegExp(r'\b\d+\b'), '<num>'),
];

/// Scrubs [text]: every volatile value becomes its placeholder so two
/// twins of the same scenario differ only in structure, never in data.
String scrubVolatile(String text) {
  var out = text;
  for (final (pattern, replacement) in kVolatilePatterns) {
    out = out.replaceAllMapped(pattern, (_) => replacement);
  }
  return out;
}

/// Finds the status-bar row inside [screenLines] (a rendered `.txt` twin,
/// ANSI-stripped): the non-empty line with the most separator-glyph runs.
/// The bar is the densest separator row by construction — transcript text
/// may contain one glyph, the bar carries one per segment boundary.
///
/// Returns null when no row carries at least two separators (a screen
/// without a status bar).
String? findStatusBarRow(List<String> screenLines, String separatorGlyph) {
  String? best;
  var bestRuns = 1;
  for (final line in screenLines) {
    if (line.trim().isEmpty) continue;
    final runs = separatorGlyph.allMatches(line).length;
    if (runs > bestRuns) {
      best = line;
      bestRuns = runs;
    }
  }
  return best;
}

/// Splits a rendered status-bar row on [separatorGlyph] into segment
/// tokens (leading/trailing blanks dropped, empty tokens dropped — the
/// band's bg-fill padding never survives as a token).
List<String> splitBarSegments(String barRow, String separatorGlyph) => barRow
    .split(separatorGlyph)
    .map((t) => t.trim())
    .where((t) => t.isNotEmpty)
    .toList(growable: false);

/// The structural signature of one status bar: each segment token reduced
/// to a shape class. Two bars of the same scenario produce EQUAL
/// signatures even when model id, cwd, cost or clock differ; a missing or
/// reordered segment shifts the signature.
///
/// Shape classes (after [scrubVolatile] has already run inside):
/// - `<path>` — path-ish token (contains a path separator after scrub);
/// - `<cost>` — dollar-prefixed token;
/// - `<pct>` — a bare percentage (context gauge);
/// - `<tok>` — `…tok` token;
/// - `<time>` — elapsed/clock token;
/// - `<word:N>` — N alphanumeric-run token (brand marks, model names, mode
///   labels, session names): the RUN COUNT is structural, wording is not
///   (fa/omp name the same scenario differently on purpose — 'test-model'
///   and 'Test Model' are both `<word:2>`).
String segmentSignature(String rawToken) {
  final token = scrubVolatile(rawToken).trim();
  if (token.isEmpty) return '';
  if (token.startsWith('<cost>')) return '<cost>';
  if (token.startsWith('<time>')) return '<time>';
  if (token.startsWith('<pct>')) return '<pct>';
  if (token == '<tok>' || token.endsWith(' tok')) return '<tok>';
  if (token.startsWith('<path>') || token.contains('/')) return '<path>';
  final words = RegExp(r'[A-Za-z0-9]+').allMatches(token).length;
  return '<word:$words>';
}

/// Full-bar signature: [splitBarSegments] + [segmentSignature] per token.
List<String> barSignature(String barRow, String separatorGlyph) =>
    splitBarSegments(barRow, separatorGlyph).map(segmentSignature).toList();

/// Structural diff of two rendered twin screens for one shared surface.
///
/// Returns human-readable findings; empty list = structurally equal.
/// Compared per surface:
/// - row count of the chrome region (non-empty trimmed lines);
/// - status-bar segment signature ([barSignature]) when a bar row exists
///   on both sides;
/// - separator glyph runs per line (the band's glyph inventory).
List<String> structuralDiff(
  List<String> faScreen,
  List<String> ompScreen, {
  required String surfaceName,
  required String separatorGlyph,
}) {
  final findings = <String>[];
  final faRows = faScreen
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);
  final ompRows = ompScreen
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);
  if (faRows.length != ompRows.length) {
    findings.add(
      '$surfaceName: chrome row count differs — fa ${faRows.length}, '
      'omp ${ompRows.length}',
    );
  }

  final faBar = findStatusBarRow(faScreen, separatorGlyph);
  final ompBar = findStatusBarRow(ompScreen, separatorGlyph);
  if (faBar == null && ompBar != null) {
    findings.add('$surfaceName: fa has no status bar, omp does');
  } else if (faBar != null && ompBar == null) {
    findings.add('$surfaceName: omp has no status bar, fa does');
  } else if (faBar != null && ompBar != null) {
    final faSig = barSignature(faBar, separatorGlyph);
    final ompSig = barSignature(ompBar, separatorGlyph);
    if (faSig.length != ompSig.length) {
      findings.add(
        '$surfaceName: segment count differs — fa ${faSig.length} '
        '$faSig, omp ${ompSig.length} $ompSig',
      );
    } else {
      for (var i = 0; i < faSig.length; i++) {
        if (faSig[i] != ompSig[i]) {
          findings.add(
            '$surfaceName: segment ${i + 1} shape differs — '
            'fa ${faSig[i]} (${splitBarSegments(faBar, separatorGlyph)[i]}), '
            'omp ${ompSig[i]} '
            '(${splitBarSegments(ompBar, separatorGlyph)[i]})',
          );
        }
      }
    }
  }
  return findings;
}
