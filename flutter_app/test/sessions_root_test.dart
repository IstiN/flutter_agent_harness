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

  // issue #701 CRAP descent #12: isFaCliInstalled's probe matrix, driven
  // through IOOverrides so every branch of the real function runs without
  // mutating the developer machine — the scripted FS answers existsSync
  // for exactly the paths handed to it.
  group('isFaCliInstalled (scripted filesystem)', () {
    bool probe(Set<String> existing) => IOOverrides.runWithIOOverrides(
      isFaCliInstalled,
      _ExistsOnlyFs(existing),
    );

    final home = Platform.environment['HOME'] ?? '';
    final pathDirs = (Platform.environment['PATH'] ?? '')
        .split(':')
        .where((d) => d.isNotEmpty)
        .toList();

    test('~/.fah alone counts as installed', () {
      expect(probe({'$home/.fah'}), isTrue);
    });

    test('every fixed candidate path is probed', () {
      for (final p in [
        '$home/.local/bin/fa',
        '$home/.local/bin/fah',
        '/opt/homebrew/bin/fa',
        '/opt/homebrew/bin/fah',
        '/usr/local/bin/fa',
        '/usr/local/bin/fah',
      ]) {
        expect(probe({p}), isTrue, reason: p);
      }
    });

    test('a fa binary in the first PATH directory counts', () {
      expect(pathDirs, isNotEmpty, reason: 'PATH is never empty on CI hosts');
      expect(probe({'${pathDirs.first}/fa'}), isTrue);
    });

    test('a fah binary in a later PATH directory counts', () {
      final later = pathDirs.length > 1 ? pathDirs[1] : pathDirs.first;
      expect(probe({'$later/fah'}), isTrue);
    });

    test('nothing anywhere means not installed', () {
      expect(probe(const {}), isFalse);
    });

    test('unrelated files never satisfy the probe', () {
      expect(
        probe({'$home/.local/bin/other', '/opt/homebrew/bin/other'}),
        isFalse,
      );
    });
  });
}

/// Answers existsSync from a fixed set of paths; everything else the
/// function might touch on the real FS is refused by [Fake].
final class _ExistsOnlyFs extends IOOverrides {
  _ExistsOnlyFs(this._existing);

  final Set<String> _existing;

  @override
  Directory createDirectory(String path) => _FakeDir(_existing.contains(path));

  @override
  File createFile(String path) => _FakeFile(_existing.contains(path));
}

final class _FakeDir extends Fake implements Directory {
  _FakeDir(this._exists);

  final bool _exists;

  @override
  bool existsSync() => _exists;
}

final class _FakeFile extends Fake implements File {
  _FakeFile(this._exists);

  final bool _exists;

  @override
  bool existsSync() => _exists;
}
