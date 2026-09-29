/// dart2js integer-shift guard (issue #1074).
///
/// dart2js bitwise shifts are 32-bit: `a << b` with `b >= 32` evaluates to
/// 0 and `1 << 31` evaluates to -2147483648, while the VM computes 64-bit
/// values. A VM unit test can never catch this (both backends agree there),
/// so — like the purity guard in `purity_js_test.dart` — this is a source
/// scan over `lib/**.dart` (pure-Dart web-compiled core; `flutter_app/` and
/// `packages/` are out of scope for v1).
///
/// Two deliberately dumb rules, no allowlist needed on a clean tree:
///
/// 1. `_wideShift` — any literal left shift by >= 31
///    (`1 << 31`, `1 << 32`, `1 << 62`, …). Fix: spell the value as a
///    literal (`0x80000000`, `0xFFFFFFFF`, `0x4000000000000000`, …).
/// 2. `_nextIntShift` — any `nextInt(... << ...)` whose bound is computed
///    by a shift of any width, forcing review (widths < 31 are actually
///    safe, e.g. `bridge_protocol.dart`'s `nextInt(1 << 16)`, which is the
///    single allowlisted site; rule 1 still scans that file).
///
/// Known v1 ceilings (fine to grow later): only `1 <<` is scanned (a
/// literal `2 << 31` or `x << 62` with a non-`1` base passes), and
/// non-literal shift widths are only checked inside `nextInt` — the
/// clamped-exponent backoff shifts (e.g. `1 << (attempt - 1).clamp(0, 5)`)
/// are safe by inspection today.
///
/// `//`-comment tails are stripped before matching so hazard comments may
/// name the offending spelling (`1 << 32`) without self-flagging. Naive
/// strip: a `//` inside a string literal also cuts the line — acceptable,
/// no lib/ code hides a wide shift behind one today.
///
/// VM-only: walks the source tree on disk.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Literal left shifts of width >= 31: 0 (or negative) on dart2js.
final _wideShift = RegExp(r'\b1 << (3[1-9]|[4-9][0-9]+)\b');

/// Any `nextInt` whose argument contains a shift — reviewed, not shipped.
final _nextIntShift = RegExp(r'\bnextInt\([^()]*<<');

/// Rule 2's only known-safe site: shift widths < 31 in a nextInt bound.
final _nextIntShiftAllowlist = ['lib/src/browser/bridge_protocol.dart'];

/// The code part of [line] (comment tails stripped).
String _stripComment(String line) {
  final cut = line.indexOf('//');
  return cut < 0 ? line : line.substring(0, cut);
}

void main() {
  test('no dart2js-unsafe integer shifts under lib/ (issue #1074)', () {
    final offenders = <String>[];
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      final lines = entry.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final code = _stripComment(lines[i]);
        final where = '${entry.path}:${i + 1}';
        if (_wideShift.hasMatch(code)) {
          offenders.add('$where: literal shift >= 31 → ${lines[i].trim()}');
        } else if (_nextIntShift.hasMatch(code) &&
            !_nextIntShiftAllowlist.any(entry.path.endsWith)) {
          offenders.add('$where: shift-fed nextInt → ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'dart2js shifts are 32-bit: `1 << 32` == 0 and `1 << 31` < 0 on '
          'web while the VM computes 64-bit values. Spell the intended '
          'value as a literal (0xFFFFFFFF, 0x80000000, …) — see issue '
          '#1074.',
    );
  });

  test('guard rules catch the planted hazards they exist for', () {
    // The `1 << 32` shape that killed every web bash call.
    expect(_wideShift.hasMatch('nextInt(1 << 32)'), isTrue);
    // Sentinel + negative-on-web widths, wherever they appear.
    expect(_wideShift.hasMatch('maxLines: 1 << 62'), isTrue);
    expect(_wideShift.hasMatch('clamp(0, 1 << 31)'), isTrue);
    expect(_wideShift.hasMatch('maxBytes: 1 << 60'), isTrue);
    // Safe spellings and safe widths stay green.
    expect(_wideShift.hasMatch('nextInt(0xFFFFFFFF)'), isFalse);
    expect(_wideShift.hasMatch('clamp(0, 0x80000000)'), isFalse);
    expect(_wideShift.hasMatch('const block = 1 << 20;'), isFalse);
    expect(_wideShift.hasMatch('1 << (attempt - 1).clamp(0, 5)'), isFalse);
    // Shift-fed nextInt is flagged for review at any width...
    expect(_nextIntShift.hasMatch('r.nextInt(1 << 16)'), isTrue);
    // ...and comments never trigger (hazard notes may name the shape).
    expect(
      _wideShift.hasMatch(_stripComment('// dart2js: `1 << 32` == 0')),
      isFalse,
    );
  });
}
