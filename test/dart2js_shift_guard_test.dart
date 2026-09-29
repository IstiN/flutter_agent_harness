/// dart2js integer-shift guard (issue #1074).
///
/// dart2js bitwise shifts are 32-bit: `a << b` with `b >= 32` evaluates to
/// 0 (counts wrap mod 32, so `1 << 100` is `1 << 4`) and `1 << 31` evaluates
/// to -2147483648, while the VM computes 64-bit values. Composite shifts go
/// negative on web too (`(r.nextInt(1 << 16) << 16) | …` leaks a `-` into
/// hex output). A VM unit test can never catch this (both backends agree
/// there), so — like the purity guard in `purity_js_test.dart` — this is a
/// source scan over `lib/**.dart` (pure-Dart web-compiled core;
/// `flutter_app/` and `packages/` are out of scope for v1).
///
/// Two deliberately dumb rules, no allowlist (none needed on a clean tree):
///
/// 1. `_wideShift` — any literal left shift by a width >= 31
///    (`1 << 31`, `1<<32`, `2 << 40`, `0x10 << 100`, …), spacing-tolerant.
///    Fix: spell the value as a literal (`0x80000000`, `0xFFFFFFFF`,
///    `0x4000000000000000`, …) or recombine draws with `*`/`+`.
/// 2. `_nextIntShift` — any `nextInt(... << ...)` whose bound is computed
///    by a shift of any width, forcing review (widths < 31 are actually
///    safe; there are none at merge time).
///
/// Known v1 ceilings (fine to grow later):
/// - only literal bases are scanned, and a literal must not continue an
///   identifier (`foo1 << 32` hides behind the lookbehind) — non-literal
///   bases/widths elsewhere are reviewed by hand; the clamped-exponent
///   backoff shifts (e.g. `1 << (attempt - 1).clamp(0, 5)`) are safe by
///   inspection today;
/// - rule 2 cannot see a shift behind nested parens
///   (`nextInt((1 << 16))`) — widths >= 31 are still caught by rule 1.
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

/// Literal left shifts of width >= 31: 0 (or negative) on dart2js. Tolerant
/// to spacing (`1<<32`, `1 <<32`, `1  <<  32`) and to any literal base
/// (`1`, `2`, `0x10`, …); the width may also exceed two digits (`1 << 100`
/// wraps to `1 << 4` on web).
final _wideShift = RegExp(
  r'(?<![\w$.])(?:0[xX][0-9a-fA-F]+|\d+)\s*<<\s*'
  r'(?:3[1-9]|[4-9][0-9]+|[1-9][0-9]{2,})\b',
);

/// Any `nextInt` whose argument contains a shift — reviewed, not shipped.
final _nextIntShift = RegExp(r'\bnextInt\([^()]*<<');

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
        } else if (_nextIntShift.hasMatch(code)) {
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
          'value as a literal (0xFFFFFFFF, 0x80000000, …) or recombine '
          'draws with * and + — see issue #1074.',
    );
  });

  test('guard rules catch the planted hazards they exist for', () {
    // The `1 << 32` shape that killed every web bash call.
    expect(_wideShift.hasMatch('nextInt(1 << 32)'), isTrue);
    // Spacing variants cannot sidestep the guard.
    expect(_wideShift.hasMatch('final x = 1<<32;'), isTrue);
    expect(_wideShift.hasMatch('final x = 1 <<32;'), isTrue);
    expect(_wideShift.hasMatch('final x = 1<< 32;'), isTrue);
    expect(_wideShift.hasMatch('final x = 1  <<  32;'), isTrue);
    // Sentinel + negative-on-web widths, wherever they appear.
    expect(_wideShift.hasMatch('maxLines: 1 << 62'), isTrue);
    expect(_wideShift.hasMatch('clamp(0, 1 << 31)'), isTrue);
    expect(_wideShift.hasMatch('maxBytes: 1 << 60'), isTrue);
    // Widths >= 100 wrap mod 32 on web (1 << 100 == 1 << 4 there).
    expect(_wideShift.hasMatch('1 << 100'), isTrue);
    // Non-1 literal bases shift just as wide.
    expect(_wideShift.hasMatch('2 << 31'), isTrue);
    expect(_wideShift.hasMatch('0x10 << 40'), isTrue);
    // Safe spellings and safe widths stay green.
    expect(_wideShift.hasMatch('nextInt(0xFFFFFFFF)'), isFalse);
    expect(_wideShift.hasMatch('clamp(0, 0x80000000)'), isFalse);
    expect(_wideShift.hasMatch('const block = 1 << 20;'), isFalse);
    expect(_wideShift.hasMatch('const kib = 64 << 10;'), isFalse);
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
