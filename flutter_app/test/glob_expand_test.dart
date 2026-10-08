// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the pure glob-expansion walker (gh-1393 WS-1): POSIX
// pathname semantics over an injected lister — sorted matches, literal
// passthrough on no match, dotfile hiding, `**` traversal, absolute and
// relative pattern shapes.
library;

import 'package:fa/sandbox/glob_expand.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory tree: path → entries. `null` value = not a directory.
GlobDirList fakeFs(Map<String, List<GlobEntry>?> tree) => (path) async {
  final normalized = path.isEmpty ? '/' : path;
  return tree[normalized];
};

void main() {
  final fs = fakeFs(const {
    '/': [
      GlobEntry('apps', isDir: true),
      GlobEntry('README.md'),
      GlobEntry('.hidden'),
      GlobEntry('a.txt'),
    ],
    '/apps': [
      GlobEntry('2048', isDir: true),
      GlobEntry('notes', isDir: true),
      GlobEntry('app.json'),
    ],
    '/apps/2048': [
      GlobEntry('app.json'),
      GlobEntry('widget.js'),
      GlobEntry('.fah', isDir: true),
    ],
    '/apps/notes': [GlobEntry('app.json')],
  });

  group('expandGlobPattern', () {
    test('single-level star expands sorted, relative shape kept', () async {
      expect(await expandGlobPattern('*.txt', '/', fs), ['a.txt']);
      expect(await expandGlobPattern('apps/*/app.json', '/', fs), [
        'apps/2048/app.json',
        'apps/notes/app.json',
      ]);
    });

    test('pattern rooted at a subdirectory (cwd)', () async {
      expect(await expandGlobPattern('*/app.json', '/apps', fs), [
        '2048/app.json',
        'notes/app.json',
      ]);
    });

    test('absolute pattern yields absolute matches', () async {
      expect(await expandGlobPattern('/apps/*/widget.js', '/', fs), [
        '/apps/2048/widget.js',
      ]);
    });

    test('question mark matches exactly one char', () async {
      expect(await expandGlobPattern('?.txt', '/', fs), ['a.txt']);
    });

    test(
      'no match passes null through (literal passthrough contract)',
      () async {
        expect(await expandGlobPattern('*.rs', '/', fs), isNull);
        expect(await expandGlobPattern('apps/*/missing.json', '/', fs), isNull);
        expect(await expandGlobPattern('nope/*/x', '/', fs), isNull);
      },
    );

    test(
      'literal pattern word is not a glob (caller short-circuits anyway)',
      () async {
        // expandShellStage only calls the walker for isGlobWord() words; the
        // walker itself also refuses, so a misrouted literal is inert.
        expect(await expandGlobPattern('README.md', '/', fs), isNull);
      },
    );

    test(
      'hidden entries stay hidden unless the segment starts with a dot',
      () async {
        expect(await expandGlobPattern('.*', '/', fs), ['.hidden']);
        // `*` alone never matches dot names (bash dotglob off).
        expect(await expandGlobPattern('apps/2048/*', '/', fs), [
          'apps/2048/app.json',
          'apps/2048/widget.js',
        ]);
      },
    );

    test(
      'literal final segment must exist (bash emits existing paths only)',
      () async {
        expect(await expandGlobPattern('apps/2048/widget.js', '/', fs), isNull);
      },
    );

    test('multi-item: three matches sort lexicographically', () async {
      expect(await expandGlobPattern('apps/*', '/', fs), [
        'apps/2048',
        'apps/app.json',
        'apps/notes',
      ]);
    });

    test('doublestar crosses directories (and matches zero levels)', () async {
      expect(await expandGlobPattern('apps/**/*.json', '/', fs), [
        'apps/2048/app.json',
        'apps/app.json',
        'apps/notes/app.json',
      ]);
    });

    test(
      'doublestar as the last segment lists the subtree (dir itself too)',
      () async {
        expect(await expandGlobPattern('apps/2048/**', '/', fs), [
          'apps/2048',
          'apps/2048/.fah',
          'apps/2048/app.json',
          'apps/2048/widget.js',
        ]);
      },
    );

    test('bracket character classes expand (gh-1393 rework)', () async {
      // Range class over the directory name.
      expect(await expandGlobPattern('apps/[0-9]*/app.json', '/', fs), [
        'apps/2048/app.json',
      ]);
      // Set class.
      expect(await expandGlobPattern('apps/[nr]otes/app.json', '/', fs), [
        'apps/notes/app.json',
      ]);
      // Mixed class + glob star in the same word.
      expect(await expandGlobPattern('[ar]*.txt', '/', fs), ['a.txt']);
      expect(await expandGlobPattern('README.[mh]d', '/', fs), ['README.md']);
    });

    test('negated classes [!...] and [^...] exclude (never cross /)',
        () async {
      expect(await expandGlobPattern('[!n]*', '/', fs), [
        'README.md',
        'a.txt',
        'apps',
      ]);
      expect(await expandGlobPattern('[^r]*.txt', '/', fs), ['a.txt']);
    });

    test('a leading ] inside a class is literal (bash []x] rule)', () async {
      final bracketFs = fakeFs(const {
        '/': [GlobEntry('x].txt'), GlobEntry('xa.txt')],
      });
      expect(await expandGlobPattern('x[]].txt', '/', bracketFs), ['x].txt']);
      expect(await expandGlobPattern('x[!]].txt', '/', bracketFs), ['xa.txt']);
    });

    test('an unclosed [ is a literal character (no match → passthrough)',
        () async {
      expect(await expandGlobPattern('apps/[20', '/', fs), isNull);
      expect(await expandGlobPattern('apps/[2048/app.json', '/', fs), isNull);
    });

    test('an out-of-order range leaves the word literal (stat format words)',
        () async {
      // Regression (wasm_shell_stat_test): `stat --format=[%q-%s] f` must
      // keep its format verbatim — bash leaves a malformed bracket
      // expression (range q-% is out of order) unchanged.
      expect(await expandGlobPattern('[%q-%s]', '/', fs), isNull);
      expect(await expandGlobPattern('[z-a]', '/', fs), isNull);
    });

    test('bracket words still hide dotfiles (the segment does not start .)',
        () async {
      expect(await expandGlobPattern('[.h]*', '/', fs), isNull);
    });
  });

  group('isGlobWord', () {
    test('star and question mark qualify', () {
      expect(isGlobWord('*.dart'), isTrue);
      expect(isGlobWord('apps/*/app.json'), isTrue);
      expect(isGlobWord('file?.txt'), isTrue);
      expect(isGlobWord('a*b'), isTrue);
    });

    test('bracket classes qualify (gh-1393 rework)', () {
      expect(isGlobWord('apps/[0-9]*/app.json'), isTrue);
      expect(isGlobWord('[!n]*'), isTrue);
    });

    test('plain words do not', () {
      expect(isGlobWord('README.md'), isFalse);
      expect(isGlobWord('apps/app.json'), isFalse);
      expect(isGlobWord(''), isFalse);
    });
  });
}
