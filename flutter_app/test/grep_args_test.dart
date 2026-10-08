// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the SHARED grep argv parser (gh-1393 WS-1): one parser
// feeds the WASI shell's rg fallback AND the web MemoryShell's Dart grep,
// so the field-evidence breakages are pinned at the source — clustered
// shorts (`-rl`), `--include=`, `--`, BRE alternation (`\|`), unicode
// pattern position, and loud POSIX-style errors for untranslatable flags.
library;

import 'package:fa/sandbox/grep_args.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseGrepArgs (shared, gh-1393)', () {
    test('positional pattern and files', () {
      final r = parseGrepArgs(['foo', 'a.txt', 'b.txt'])!;
      expect(r.pattern, 'foo');
      expect(r.files, ['a.txt', 'b.txt']);
      expect(r.flags, isEmpty);
      expect(r.quiet, isFalse);
      expect(r.isUsable, isTrue);
    });

    test(
      'clustered shorts split per letter (was: `-rl` became the pattern)',
      () {
        final r = parseGrepArgs(['-rl', 'счёт', 'apps'])!;
        expect(r.recursive, isTrue);
        expect(r.flags, ['-l']);
        expect(r.pattern, 'счёт');
        expect(r.files, ['apps']);
      },
    );

    test('clustered shorts combine quiet/count/line-number', () {
      final r = parseGrepArgs(['-rnc', 'p'])!;
      expect(r.recursive, isTrue);
      expect(r.flags, ['-n', '-c']);
      expect(r.pattern, 'p');
    });

    test('-i -n as separate flags stay separate', () {
      expect(parseGrepArgs(['-i', '-n', 'p'])!.flags, ['-i', '-n']);
    });

    test('--include=GLOB translates to the include set', () {
      final r = parseGrepArgs(['-r', '--include=*.json', 'TAP', 'apps'])!;
      expect(r.includeGlobs, {'*.json'});
      expect(r.pattern, 'TAP');
      // (rg forwarding assembles `-g` from the set — see _grepBuiltin.)
    });

    test('--exclude=GLOB translates to the exclude set', () {
      expect(parseGrepArgs(['--exclude=dist', 'p'])!.excludeGlobs, {'dist'});
    });

    test('-e consumes the next arg as pattern', () {
      final r = parseGrepArgs(['-e', 'pat', 'file'])!;
      expect(r.pattern, 'pat');
      expect(r.files, ['file']);
    });

    test('-e without a value returns null', () {
      expect(parseGrepArgs(['-e']), isNull);
      expect(parseGrepArgs(['file', '-e']), isNull);
    });

    test('-- ends option parsing', () {
      final r = parseGrepArgs(['-r', '--', '-weird', 'f.txt'])!;
      expect(r.pattern, '-weird');
      expect(r.files, ['f.txt']);
    });

    test('BRE alternation translates to ERE (was: broken on both shells)', () {
      expect(parseGrepArgs(['foo\\|bar'])!.pattern, 'foo|bar');
      expect(parseGrepArgs([r'a\(b\)\{2\}'])!.pattern, 'a(b){2}');
    });

    test('other escapes pass through untouched', () {
      expect(parseGrepArgs([r'a\sb'])!.pattern, r'a\sb');
      expect(parseGrepArgs([r'\\|'])!.pattern, r'\\|');
    });

    test('-F keeps the pattern verbatim (fixed strings)', () {
      expect(parseGrepArgs(['-F', r'a\|b'])!.pattern, r'a\|b');
    });

    test('-E keeps BRE spellings verbatim (ERE reads them literally)', () {
      expect(parseGrepArgs(['-E', r'a\|b'])!.pattern, r'a\|b');
    });

    test('untranslatable short flag errors POSIX-style (gh-1393 E2)', () {
      final r = parseGrepArgs(['-Z', 'p'])!;
      expect(r.isUsable, isFalse);
      expect(r.error, contains("invalid option -- 'Z'"));
    });

    test('untranslatable long flag errors POSIX-style', () {
      final r = parseGrepArgs(['--color=always', 'p'])!;
      expect(r.isUsable, isFalse);
      expect(r.error, contains("unrecognized option '--color=always'"));
    });

    test('context flags consume their count', () {
      expect(parseGrepArgs(['-A', '2', 'p'])!.flags, ['-A', '2']);
      expect(parseGrepArgs(['-B3', 'p'])!.flags, ['-B', '3']);
      expect(parseGrepArgs(['-C', '1', 'p'])!.flags, ['-C', '1']);
      final r = parseGrepArgs(['-A', 'p'])!;
      expect(r.isUsable, isFalse);
    });

    test('-h translates to rg no-filename, -H is a no-op', () {
      expect(parseGrepArgs(['-h', 'p'])!.flags, ['-I']);
      expect(parseGrepArgs(['-H', 'p'])!.flags, isEmpty);
    });

    test('bare - is a stdin operand, never the pattern', () {
      final r = parseGrepArgs(['-c', '-', 'p'])!;
      expect(r.flags, ['-c']);
      // `-` first: it becomes the pattern slot (grep treats a lone `-` as
      // the stdin operand only in file position — first positional wins).
      expect(r.pattern, '-');
    });

    test('quiet flags set quiet', () {
      for (final f in ['-q', '--quiet', '--silent']) {
        expect(parseGrepArgs([f, 'p'])!.quiet, isTrue, reason: f);
      }
    });

    test('-m consumes its count, -mN stays as-is', () {
      expect(parseGrepArgs(['-m', '3', 'p'])!.flags, ['-m', '3']);
      expect(parseGrepArgs(['-m3', 'p'])!.flags, ['-m3']);
    });

    test('long flag translations cover the documented set', () {
      expect(parseGrepArgs(['--ignore-case', 'p'])!.flags, ['-i']);
      expect(parseGrepArgs(['--count', 'p'])!.flags, ['-c']);
      expect(parseGrepArgs(['--line-number', 'p'])!.flags, ['-n']);
      expect(parseGrepArgs(['--fixed-strings', 'p'])!.flags, ['-F']);
      expect(parseGrepArgs(['--files-with-matches', 'p'])!.flags, ['-l']);
      expect(parseGrepArgs(['--recursive', 'p'])!.recursive, isTrue);
    });

    test('the remaining long translations land in flags', () {
      expect(parseGrepArgs(['--invert-match', 'p'])!.flags, ['-v']);
      expect(parseGrepArgs(['--word-regexp', 'p'])!.flags, ['-w']);
      expect(parseGrepArgs(['--line-regexp', 'p'])!.flags, ['-x']);
      expect(parseGrepArgs(['--only-matching', 'p'])!.flags, ['-o']);
      expect(parseGrepArgs(['--files-without-match', 'p'])!.flags, ['-L']);
      expect(
        parseGrepArgs(['--dereference-recursive', 'p'])!.flags,
        isEmpty,
      );
    });

    test('--extended-regexp skips the BRE pass, like -E', () {
      expect(parseGrepArgs(['--extended-regexp', r'a\|b'])!.pattern, r'a\|b');
    });

    test('--regexp= sets the pattern', () {
      final r = parseGrepArgs(['--regexp=TAP', 'apps'])!;
      expect(r.pattern, 'TAP');
      expect(r.files, ['apps']);
    });

    test('--max-count=N translates to the -m pair', () {
      expect(parseGrepArgs(['--max-count=4', 'p'])!.flags, ['-m', '4']);
    });

    test('--max-count with a non-numeric value errors (exit 2 class)', () {
      final r = parseGrepArgs(['--max-count=many', 'p'])!;
      expect(r.isUsable, isFalse);
      expect(r.error, contains('invalid max count: many'));
    });

    test('-mN with a non-numeric count errors', () {
      final r = parseGrepArgs(['-mmany', 'p'])!;
      expect(r.isUsable, isFalse);
      expect(r.error, contains('invalid max count: many'));
    });

    test('detached -m at the end of argv forwards bare -m', () {
      expect(parseGrepArgs(['-m'])!.flags, ['-m']);
    });

    test('attached -A/-B/-C with a non-numeric count errors', () {
      for (final letter in ['A', 'B', 'C']) {
        final r = parseGrepArgs(['-$letter${letter}1', 'p'])!;
        expect(r.isUsable, isFalse, reason: '-$letter');
        expect(r.error, contains('invalid context length: ${letter}1'));
      }
    });

    test('accepted no-op short letters change nothing', () {
      for (final f in ['-T', '-d', '-s']) {
        final r = parseGrepArgs([f, 'p'])!;
        expect(r.flags, isEmpty, reason: f);
        expect(r.isUsable, isTrue, reason: f);
        expect(r.pattern, 'p', reason: f);
      }
    });

    test('the remaining forwardable short letters ride verbatim', () {
      expect(parseGrepArgs(['-o', 'p'])!.flags, ['-o']);
      expect(parseGrepArgs(['-x', 'p'])!.flags, ['-x']);
      expect(parseGrepArgs(['-a', 'p'])!.flags, ['-a']);
      expect(parseGrepArgs(['-wvin', 'p'])!.flags, ['-w', '-v', '-i', '-n']);
    });

    test('-P keeps the pattern verbatim (PCRE skips the BRE pass)', () {
      expect(parseGrepArgs(['-P', r'a\|b'])!.pattern, r'a\|b');
    });

    test('a mid-cluster error keeps nothing usable and stops parsing', () {
      final r = parseGrepArgs(['-rnZ', 'p', 'f'])!;
      expect(r.isUsable, isFalse);
      expect(r.error, contains("invalid option -- 'Z'"));
      // Positional operands after the bad letter never become the pattern.
      expect(r.pattern, isNull);
    });

    test('translateBREToERE leaves plain patterns alone', () {
      expect(translateBREToERE('plain.text'), 'plain.text');
      expect(translateBREToERE(''), '');
    });

    test('translateBREToERE edge shapes (trailing backslash, escaped '
        'backslash pairs)', () {
      // A trailing lone backslash has no escape target — verbatim.
      expect(translateBREToERE(r'trail\'), r'trail\');
      // `\\` stays a literal backslash pair; the `(` after it is a literal
      // plain char (not a BRE group opener) — unchanged overall.
      expect(translateBREToERE(r'a\\(b'), r'a\\(b');
      // A real BRE group still translates next to a literal pair.
      expect(translateBREToERE(r'a\\b\|(c)'), r'a\\b|(c)');
    });
  });
}
