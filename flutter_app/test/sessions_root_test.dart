@TestOn('vm')
library;

import 'dart:io';

import 'package:fa/services/sessions_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sessionsGroupDir', () {
    test('app group layout under the home', () {
      expect(
        sessionsGroupDir('/Users/dev'),
        '/Users/dev/Library/Group Containers/'
        'group.dev.fa1.shared/fa/sessions',
      );
    });
  });

  group('probedSessionsGroupDir', () {
    test('creates and returns a writable group dir', () {
      final tmp = Directory.systemTemp.createTempSync('fah_sessions_root');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final dir = probedSessionsGroupDir(tmp.path);
      expect(dir, sessionsGroupDir(tmp.path));
      expect(Directory(dir!).existsSync(), isTrue);
    });

    test('unusable home degrades to null (never throws)', () {
      // A regular FILE where the home directory should be: creating the
      // group dir under it fails (ENOTDIR) — the probe must return null
      // so the caller falls back to ~/.fah/sessions.
      final tmp = Directory.systemTemp.createTempSync('fah_sessions_root');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/not-a-dir')..writeAsStringSync('');
      expect(probedSessionsGroupDir(file.path), isNull);
    });
  });

  group('macSessionRootCandidates', () {
    test('default only when neither candidate exists', () {
      final roots = macSessionRootCandidates(
        home: '/h',
        defaultRoot: '/h/sessions',
        exists: (_) => false,
      );
      expect(roots, ['/h/sessions']);
    });

    test('adds existing group and fallback dirs', () {
      final roots = macSessionRootCandidates(
        home: '/h',
        defaultRoot: '/h/sessions',
        exists: (path) =>
            path.endsWith('.fah/sessions') || path.contains('Group'),
      );
      expect(
        roots,
        unorderedEquals([
          '/h/sessions',
          sessionsGroupDir('/h'),
          '/h/.fah/sessions',
        ]),
      );
    });

    test('never duplicates the default root', () {
      final roots = macSessionRootCandidates(
        home: '/h',
        defaultRoot: sessionsGroupDir('/h'),
        exists: (_) => true,
      );
      expect(roots, [sessionsGroupDir('/h'), '/h/.fah/sessions']);
    });
  });

  group('platform-independent roots (off macOS)', () {
    test(
      'defaultSessionsRoot stays under the cwd',
      () {
        expect(defaultSessionsRoot('/work'), '/work/sessions');
      },
      skip: Platform.isMacOS ? 'macOS resolves the App Group container' : null,
    );

    test('allSessionRoots collapses to the default', () {
      expect(allSessionRoots('/work/sessions'), ['/work/sessions']);
    }, skip: Platform.isMacOS ? 'macOS lists extra candidates' : null);
  });

  // issue #701 CRAP descent #12: faCliProbe's full branch matrix — the
  // platform gate, ~/.fah, the fixed install locations and every PATH
  // dir — driven through the injected seam (faCliProbe) so it runs
  // identically on every CI host; the IO shell (isFaCliInstalled)
  // stays a one-liner over Platform/environment.
  group('faCliProbe (isFaCliInstalled core)', () {
    bool probe(
      Set<String> existing, {
      bool isMacOS = true,
      String home = '/h',
      String pathEnv = '',
    }) => faCliProbe(
      isMacOS: isMacOS,
      home: home,
      pathEnv: pathEnv,
      pathExists: existing.contains,
    );

    test('off macOS nothing counts as installed', () {
      expect(probe({'/h/.fah'}, isMacOS: false), isFalse);
      expect(probe({'/opt/homebrew/bin/fa'}, isMacOS: false), isFalse);
    });

    test('~/.fah alone counts as installed', () {
      expect(probe({'/h/.fah'}), isTrue);
    });

    test('every fixed candidate path is probed', () {
      for (final p in [
        '/h/.local/bin/fa',
        '/h/.local/bin/fah',
        '/opt/homebrew/bin/fa',
        '/opt/homebrew/bin/fah',
        '/usr/local/bin/fa',
        '/usr/local/bin/fah',
      ]) {
        expect(probe({p}), isTrue, reason: p);
      }
    });

    test('a fa binary in the first PATH directory counts', () {
      expect(probe({'/usr/bin/fa'}, pathEnv: '/usr/bin:/bin'), isTrue);
    });

    test('a fah binary in a later PATH directory counts', () {
      expect(probe({'/bin/fah'}, pathEnv: '/usr/bin:/bin'), isTrue);
    });

    test('empty PATH segments are skipped, not probed', () {
      expect(probe(const {}, pathEnv: '::/usr/bin::'), isFalse);
    });

    test('nothing anywhere means not installed', () {
      expect(probe(const {}), isFalse);
    });

    test('unrelated files never satisfy the probe', () {
      expect(
        probe({'/h/.local/bin/other', '/opt/homebrew/bin/other'}),
        isFalse,
      );
    });
  });
}
