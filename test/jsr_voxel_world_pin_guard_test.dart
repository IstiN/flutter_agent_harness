// gh-1441 — the Fa app must wire the bridge-owned voxel world into every
// JsonWidgetRenderer it builds.
//
// js_widget_runtime 0.4.156 renders a `voxel` node as the "Voxel world"
// placeholder (Icons.landscape) exactly when the renderer's `voxelWorld`
// is null (json_widget_renderer.dart `_voxel`). The runtime engine exposes
// its bridge-owned world (`JsWidgetEngine.voxelWorld`, js_widget_engine_
// wrapper.dart:77 — the JsWidgetBridge creates the world eagerly at start,
// js_widget_bridge.dart:134), but the Fa app constructed the renderer
// without `voxelWorld` at its construction sites, so fa-craft /
// voxel-sandbox resolved their voxel probes, uploaded chunk meshes — and
// the screen showed the placeholder.
//
// The first cut of this guard hardcoded the two surfaces known then and
// certified completeness it did not have — `app_tile_host.dart` (the
// launcher board tile) was a third live construction site rendering
// `engine.tree` without `voxelWorld:` (gh-1441 review, BLOCKING). The scan
// below is therefore DIRECTORY-WIDE: every `JsonWidgetRenderer(` in
// `flutter_app/lib` must pass `voxelWorld:`, so a fourth site can never
// silently escape.
//
// Deliberately static asserts over the committed sources (the
// jsr_host_call_pin_guard_test.dart / nightly_desktop_leg_guard_test.dart
// pattern) so the guard runs without the native JS bridge and blocks merge
// even when all widget/E2E suites are green (ticket REG-1).
import 'dart:io';

import 'package:test/test.dart';

/// The app source tree scanned for renderer constructions. Every `.dart`
/// file under it is in scope — a new surface (or a renderer moved outside
/// `apps/`) is picked up without touching this guard.
const rendererRoot = 'flutter_app/lib';

/// The construction sites gh-1441 knows about — the floor below fails red
/// if the scan stops finding them (tree moved/renamed, scanner broken),
/// so the guard can never turn vacuously green.
const knownSurfaces = <String, String>{
  'fullscreen app view': 'flutter_app/lib/apps/js_app_view.dart',
  'live widget tile': 'flutter_app/lib/apps/dynamic_widget_tile.dart',
  'launcher board tile': 'flutter_app/lib/apps/app_tile_host.dart',
};

const engineSource = 'flutter_app/lib/apps/js_app_engine.dart';

/// Masks [source] for structural scanning: `//` line comments, `/* */`
/// block comments and string-literal interiors (single/double quotes,
/// `'''`/`"""` triples, `r''` raw strings, `\` escapes) are replaced with
/// spaces. The result has EXACTLY the original length, so offsets and line
/// numbers taken from the masked text are valid against the original.
///
/// Accepted input contract: ordinary Dart source. A truncated file (an
/// unterminated string or comment) masks the whole tail — constructions
/// after it disappear, which trips the [knownSurfaces] floor below into a
/// RED with a "scan found nothing" reason. Failure direction is false RED,
/// never false GREEN.
String maskedForScan(String source) {
  final out = List<int>.filled(source.length, 0x20);
  var i = 0;
  void keep(int index) => out[index] = source.codeUnitAt(index);

  /// Masks one position — a space, except newlines survive so line
  /// numbers taken from the masked text stay valid against the original.
  void mask(int index) {
    if (source[index] != '\n') out[index] = 0x20;
  }

  bool wordChar(int index) {
    if (index < 0 || index >= source.length) return false;
    final c = source.codeUnitAt(index);
    return (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x30 && c <= 0x39) ||
        c == 0x5F;
  }

  /// Consumes a string literal whose opening quote(s) start at [start]
  /// and returns the index just past the closing quote. [raw] strings
  /// treat `\` literally (and never interpolate). The interior is masked
  /// (newlines preserved), INCLUDING `${...}` interpolation spans: the
  /// masker brace-matches from `${` to its closing `}` and masks the
  /// whole span, so nested quotes inside an interpolation (`'${a['k']}'`)
  /// can neither terminate the outer string nor leave junk parens for
  /// [balancedArgs]. A `}` hiding inside a NESTED string of an
  /// interpolation could extend the mask past the real end — masking
  /// never adds matches, so the failure direction is the documented
  /// false RED only.
  int consumeString(int start, String quote, {required bool raw}) {
    final triple = source.startsWith(quote + quote, start + 1);
    final openLen = triple ? 3 : 1;
    for (var k = start; k < start + openLen && k < source.length; k++) {
      keep(k);
    }
    i = start + openLen;
    while (i < source.length) {
      final ch = source[i];
      if (!raw && ch == r'\') {
        // Escape: keep both characters verbatim, skip the escaped one.
        keep(i);
        if (i + 1 < source.length) keep(i + 1);
        i += 2;
        continue;
      }
      if (!raw && ch == r'$' && source.startsWith('{', i + 1)) {
        // String interpolation `${...}`: mask the brace-matched span.
        mask(i);
        mask(i + 1);
        i += 2;
        var braceDepth = 1;
        while (i < source.length && braceDepth > 0) {
          final c = source[i];
          mask(i);
          i++;
          if (c == '{') braceDepth++;
          if (c == '}') braceDepth--;
        }
        continue;
      }
      if (source.startsWith(quote, i) &&
          (!triple || source.startsWith(quote + quote + quote, i))) {
        final close = triple ? i + 3 : i + 1;
        for (var k = i; k < close && k < source.length; k++) {
          keep(k);
        }
        return close;
      }
      mask(i);
      i++;
    }
    return i; // unterminated: caller sees a masked tail (false RED guard)
  }

  while (i < source.length) {
    final ch = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (ch == '/' && next == '/') {
      // Line comment: mask through the end of the line (mask() keeps the
      // newline, so line numbering survives).
      while (i < source.length && source[i] != '\n') {
        mask(i);
        i++;
      }
    } else if (ch == '/' && next == '*') {
      // Block comment: mask through the closing `*/` (or the tail).
      keep(i);
      keep(i + 1);
      i += 2;
      while (i < source.length) {
        if (source[i] == '*' && i + 1 < source.length && source[i + 1] == '/') {
          keep(i);
          keep(i + 1);
          i += 2;
          break;
        }
        mask(i);
        i++;
      }
    } else if ((ch == "'" || ch == '"') &&
        !(ch == "'" && source.startsWith("'''", i)) &&
        !(ch == '"' && source.startsWith('"""', i))) {
      // Raw strings: an r prefix directly attached to the quote.
      final raw = wordChar(i - 1) && source[i - 1] == 'r';
      i = consumeString(i, ch, raw: raw);
    } else if (source.startsWith("'''", i) || source.startsWith('"""', i)) {
      final quote = source[i];
      i = consumeString(i, quote, raw: false);
    } else {
      keep(i);
      i++;
    }
  }
  return String.fromCharCodes(out);
}

/// The balanced text of the call whose arguments open at [openParen] —
/// from `(` through its matching `)` — or null when unbalanced. Runs on
/// [maskedForScan] output: comments and string interiors are spaces, so
/// parens inside literals can never desync the counter.
String? balancedArgs(String maskedSource, int openParen) {
  var depth = 0;
  for (var i = openParen; i < maskedSource.length; i++) {
    final ch = maskedSource[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return maskedSource.substring(openParen, i + 1);
    }
  }
  return null;
}

/// Strips every nested balanced `(...)` group from captured constructor
/// [args] (run them through this AFTER masking), leaving only the
/// construction's OWN top-level tokens. The wiring check
/// (`contains('voxelWorld:')`) reads THIS, never the raw args — a
/// `voxelWorld:` that appears only inside a nested call
/// (`JsonWidgetRenderer(theme: resolve(voxelWorld: w))`) is not a wiring
/// and must read as unwired (gh-1441 review round 2, residual path 1 —
/// the only false-GREEN shape `contains` over raw args had).
String topLevelArgs(String args) {
  // [args] is the balanced `(...)` span starting at the construction's
  // own opening paren — drop that frame first, then strip the nested
  // groups inside it.
  var body = args;
  if (body.startsWith('(') && body.endsWith(')') && body.length >= 2) {
    body = body.substring(1, body.length - 1);
  }
  final out = StringBuffer();
  var depth = 0;
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    if (ch == '(') {
      depth++;
      continue;
    }
    if (ch == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth == 0) out.write(ch);
  }
  return out.toString();
}

/// Every `JsonWidgetRenderer(` construction site as (path, lineNo, args),
/// scanned across every `.dart` file under [rendererRoot].
List<(String, int, String)> rendererConstructionsInTree() {
  final sites = <(String, int, String)>[];
  for (final entity in Directory(rendererRoot).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll('\\', '/');
    final source = entity.readAsStringSync();
    final masked = maskedForScan(source);
    var from = 0;
    while (true) {
      final at = masked.indexOf('JsonWidgetRenderer(', from);
      if (at < 0) break;
      final line = masked.substring(0, at).split('\n').length;
      // An unbalanced tail (truncated file) captures no args — the site
      // drops out and the knownSurfaces floor turns the run red with a
      // clear reason (the documented false-RED direction, never false
      // GREEN).
      sites.add((
        path,
        line,
        balancedArgs(masked, at + 'JsonWidgetRenderer'.length) ?? '',
      ));
      from = at + 'JsonWidgetRenderer('.length;
    }
  }
  return sites;
}

void main() {
  group('gh-1441 voxelWorld wiring guard', () {
    test('every Fa-app JsonWidgetRenderer construction passes voxelWorld:', () {
      final sites = rendererConstructionsInTree();
      // Floor: the three surfaces gh-1441 wired must stay visible to the
      // scan — if one disappears the tree moved or the scanner broke, and
      // a green run would mean nothing.
      final seen = sites.map((s) => s.$1).toSet();
      for (final entry in knownSurfaces.entries) {
        expect(
          seen.contains(entry.value),
          isTrue,
          reason:
              '${entry.value} (${entry.key}): the directory-wide scan no '
              'longer sees a JsonWidgetRenderer( construction — the file '
              'moved/renamed or the scanner broke; fix the guard before '
              'trusting a green run',
        );
      }
      expect(
        sites.length,
        greaterThanOrEqualTo(knownSurfaces.length),
        reason:
            'the scan found fewer constructions than the known '
            'surfaces — the scanner is undercounting',
      );
      for (final (path, line, args) in sites) {
        expect(
          topLevelArgs(args),
          contains('voxelWorld:'),
          reason:
              '$path builds JsonWidgetRenderer at :$line without '
              '`voxelWorld:` — every `voxel` node in the tree degrades to '
              'the "Voxel world" placeholder (gh-1441). Wire the engine '
              'bridge world as a DIRECT argument: '
              '`voxelWorld: engine.voxelWorld` (mirrors the webViewHost/'
              'js3dHost wiring; a voxelWorld: only inside a nested call '
              'does not count).',
        );
      }
    });

    test('JsAppEngine exposes the runtime engine voxelWorld', () {
      final source = maskedForScan(File(engineSource).readAsStringSync());
      expect(
        source,
        contains('JsVoxelWorld? get voxelWorld'),
        reason:
            'JsAppEngine keeps the JsWidgetEngine private — without a '
            'voxelWorld accessor the surfaces have nothing to pass to '
            'JsonWidgetRenderer (gh-1441)',
      );
      // Delegation to the live engine (null before start / after dispose —
      // reload then re-wires the CURRENT world, never a stale one).
      expect(
        source,
        contains('get voxelWorld => _engine?.voxelWorld'),
        reason:
            'voxelWorld must delegate to the CURRENT _engine: a cached '
            'world survives dispose/reload and repaints a disposed world '
            '(gh-1441 AC5)',
      );
      // The one-shot diagnostic is re-armed per boot and gated on a LIVE
      // engine (gh-1441 review): `_start()` nulls `_engine` before the
      // async dispose/boot while `tree.value` still publishes the old
      // tree — a rebuild in that gap must not spend the one-shot, and a
      // fired flag must not survive into the next boot of the same
      // instance.
      expect(
        source,
        contains('_unwiredVoxelNoted = false'),
        reason:
            '_start() must re-arm the one-shot unwired-voxel diagnostic — '
            'a restart of the same instance would otherwise never report a '
            'genuinely-unwired state again (gh-1441 review)',
      );
      expect(
        source,
        contains('engine == null || engine.voxelWorld != null'),
        reason:
            'noteUnwiredVoxelWorld must require a LIVE engine: the boot '
            'gap (null _engine, old tree still publishing) is not the AC3 '
            'subject — firing there warns on shipped backends and spends '
            'the one-shot (gh-1441 review)',
      );
    });
  });

  group('gh-1441 scanner hardening (gh-1441 review: false-red risks)', () {
    // The first cut tracked only `'` strings and counted parens inside
    // literals — a `"https://x"` URL truncated the line at `//` and an
    // argument string containing `(` desynced balancedArgs. Both desyncs
    // end in a false RED (never false GREEN); these pins keep it that way
    // by construction.
    test('double-quoted strings with // survive intact', () {
      const source = '''
final url = "https://x";
final renderer = JsonWidgetRenderer(onEvent: _, note: "see docs://a(b)", voxelWorld: w);
''';
      final masked = maskedForScan(source);
      expect(masked, hasLength(source.length)); // offsets stay valid
      final site = rendererConstructionsOf(masked).single;
      expect(site.$2, 2, reason: 'line numbers survive masking');
      expect(site.$3, contains('voxelWorld:'));
      // The `//` inside the URL string must not truncate the LINE: the
      // construction AFTER it on the same line stays visible.
      const sameLine =
          'final r = JsonWidgetRenderer(note: "https://x", voxelWorld: w);';
      expect(
        rendererConstructionsOf(maskedForScan(sameLine)).single.$3,
        contains('voxelWorld:'),
      );
    });

    test('commented-out constructions are not counted, block comments mask '
        'nested quotes', () {
      const source = '''
// final r = JsonWidgetRenderer(onEvent: _); // it's out of the tree
/* final r2 = JsonWidgetRenderer(onEvent: _, voxelWorld: "w"); */
final r3 = JsonWidgetRenderer(onEvent: _, voxelWorld: w);
''';
      final masked = maskedForScan(source);
      expect(rendererConstructionsOf(masked), hasLength(1));
      expect(masked, hasLength(source.length));
    });

    test('raw strings, triple quotes and escapes do not desync the mask', () {
      const source = '''
final a = r'it\\'s raw // not a comment';
final b = \'\'\'
multi "line" // string with (parens)
\'\'\';
final c = 'escaped \\' paren ( stays literal';
final d = JsonWidgetRenderer(onEvent: _, voxelWorld: w);
''';
      final masked = maskedForScan(source);
      expect(masked, hasLength(source.length));
      expect(
        rendererConstructionsOf(masked).single.$3,
        contains('voxelWorld:'),
      );
    });

    test('parens inside string arguments cannot truncate balancedArgs', () {
      const source =
          "final r = JsonWidgetRenderer(label: '(x)', voxelWorld: w);";
      final masked = maskedForScan(source);
      expect(
        rendererConstructionsOf(masked).single.$3,
        contains('voxelWorld:'),
        reason: 'the `(x)` inside the string must not end the arg capture',
      );
    });

    test('an unterminated string masks the tail — the known-surface floor '
        'goes red, never vacuous green', () {
      const source = "final s = 'unterminated;\nfinal r = JsonWidgetRenderer(";
      final masked = maskedForScan(source);
      expect(rendererConstructionsOf(masked), isEmpty);
    });

    test('a voxelWorld only inside a NESTED call is not a wiring — the '
        'guard must not false-GREEN on contains-over-raw-args', () {
      // gh-1441 review round 2, residual path 1: contains('voxelWorld:')
      // over the RAW captured args matches a nested call inside the args.
      // topLevelArgs strips nested balanced groups, so the guard sees the
      // construction's OWN arguments — this shape reads as UNWIRED (RED).
      const source =
          'final r = JsonWidgetRenderer(theme: resolve(voxelWorld: w));';
      final site = rendererConstructionsOf(maskedForScan(source)).single;
      expect(
        site.$3,
        contains('voxelWorld:'),
        reason: 'precondition: the raw args DO carry the token',
      );
      expect(
        topLevelArgs(site.$3),
        isNot(contains('voxelWorld:')),
        reason: 'the construction itself omits voxelWorld: — unwired',
      );
    });

    test('a direct top-level voxelWorld survives nested-group stripping', () {
      const source =
          'final r = JsonWidgetRenderer(voxelWorld: w, theme: resolve(x));';
      final site = rendererConstructionsOf(maskedForScan(source)).single;
      expect(topLevelArgs(site.$3), contains('voxelWorld:'));
    });

    test('string interpolation \${...} cannot desync balancedArgs', () {
      // gh-1441 review round 2, residual path 2: the masker used to close
      // the outer string at the inner quote of 'v: ${cfg['k']} )', leaving
      // the tail as code — junk parens in balancedArgs' reach.
      const source = '''
final note = 'v: \${cfg['k']} )';
final r = JsonWidgetRenderer(onEvent: _, voxelWorld: w);
''';
      final site = rendererConstructionsOf(maskedForScan(source)).single;
      expect(site.$2, 2, reason: 'line numbers survive the mask');
      expect(
        topLevelArgs(site.$3),
        contains('voxelWorld:'),
        reason:
            'the `)` inside the interpolation must not end the '
            'argument capture',
      );
    });
  });
}

/// Convenience wrapper: mask then scan one in-memory source.
List<(String, int, String)> rendererConstructionsOf(String source) {
  final masked = maskedForScan(source);
  final sites = <(String, int, String)>[];
  var from = 0;
  while (true) {
    final at = masked.indexOf('JsonWidgetRenderer(', from);
    if (at < 0) break;
    final line = masked.substring(0, at).split('\n').length;
    final args = balancedArgs(masked, at + 'JsonWidgetRenderer'.length);
    // An unbalanced tail (truncated file) captures no args — the site
    // disappears, which is the documented false-RED direction.
    sites.add(('memory', line, args ?? ''));
    from = at + 'JsonWidgetRenderer('.length;
  }
  return sites;
}
