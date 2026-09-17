import 'package:fa/services/cli_session_presence.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sessionRootAndSlugFromPath', () {
    test('parses root and slug from a session JSONL path', () {
      expect(
        sessionRootAndSlugFromPath('/sessions/slug-1/abc.jsonl'),
        ('/sessions', 'slug-1'),
      );
    });

    test('null and empty paths parse to null', () {
      expect(sessionRootAndSlugFromPath(null), isNull);
      expect(sessionRootAndSlugFromPath(''), isNull);
    });

    test('paths without both separators parse to null', () {
      expect(sessionRootAndSlugFromPath('noslash'), isNull);
      expect(sessionRootAndSlugFromPath('/onlyone'), isNull);
      expect(sessionRootAndSlugFromPath('/a/b.jsonl'), isNull);
    });

    test('slug segments may contain anything but slashes', () {
      expect(
        sessionRootAndSlugFromPath('/root/we ird/-slug-/f.jsonl'),
        ('/root/we ird', '-slug-'),
      );
    });
  });

  group('sessionRootAndSlugForPath', () {
    test('derives from the session path when well-formed', () {
      final (root, slug) = sessionRootAndSlugForPath(
        defaultRoot: '/default',
        sessionPath: '/sessions/ws/abc.jsonl',
        fallbackCwd: '/work',
      );
      expect(root, '/sessions');
      expect(slug, 'ws');
    });

    test('falls back to the default root plus encoded cwd otherwise',
        () {
      for (final sessionPath in [null, '', 'junk', '/one']) {
        final (root, slug) = sessionRootAndSlugForPath(
          defaultRoot: '/default',
          sessionPath: sessionPath,
          fallbackCwd: '/work dir',
        );
        expect(root, '/default', reason: 'path: $sessionPath');
        expect(
          slug,
          encodeSessionCwd('/work dir'),
          reason: 'path: $sessionPath',
        );
      }
    });
  });
}
