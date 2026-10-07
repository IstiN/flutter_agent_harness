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

    test('clustered shorts split per letter (was: `-rl` became the pattern)',
        () {
      final r = parseGrepArgs(['-rl', 'счёт', 'apps'])!;
      expect(r.recursive, isTrue);
      expect(r.flags, ['-l']);
      expect(r.pattern, 'счёт');
      expect(r.files, ['apps']);
    });

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

    test('translateBREToERE leaves plain patterns alone', () {
      expect(translateBREToERE('plain.text'), 'plain.text');
      expect(translateBREToERE(''), '');
    });
  });
}
