import 'package:flutter_agent_harness/src/utils/frontmatter_parser.dart';
import 'package:test/test.dart';

/// Coverage for the shared YAML frontmatter parser (issue #1234: the
/// `parseFrontmatter` wrapper sat at 0% coverage — CC 3 pure coverage
/// debt — while only the typed variant was exercised via skill loading).
void main() {
  group('parseFrontmatter', () {
    test('text without a frontmatter block is all body', () {
      final (frontmatter, body) = parseFrontmatter('just a body\n');
      expect(frontmatter, isEmpty);
      expect(body, 'just a body\n');
    });

    test('parses the fenced block and trims values', () {
      const text = '---\nname: security-review\nreadOnly: true\n'
          '---\nYou are a security reviewer.\n';
      final (frontmatter, body) = parseFrontmatter(text);
      expect(frontmatter, {
        'name': 'security-review',
        'readOnly': 'true',
      });
      expect(body, 'You are a security reviewer.\n');
    });

    test('drops empty values from the flat map', () {
      const text = '---\nname: x\ndescription: ""\n---\nbody';
      final (frontmatter, body) = parseFrontmatter(text);
      expect(frontmatter, {'name': 'x'});
      expect(body, 'body');
    });

    test('malformed YAML frontmatter degrades to plain body', () {
      // Tab indentation is a hard YAML parse error.
      const text = '---\n\ta: b\n---\nsurviving body\n';
      final (frontmatter, body) = parseFrontmatter(text);
      expect(frontmatter, isEmpty);
      expect(body, 'surviving body\n');
    });

    test('typed variant preserves lists, booleans, and nested maps', () {
      const text = '---\ntools: [read, grep]\nreadOnly: true\n'
          'meta:\n  owner: qa\n---\nbody text';
      final (frontmatter, body) = parseFrontmatterTyped(text);
      expect(frontmatter['tools'], ['read', 'grep']);
      expect(frontmatter['readOnly'], true);
      expect(frontmatter['meta'], {'owner': 'qa'});
      expect(body, 'body text');
    });
  });

  group('frontmatterWellFormed (gh-1440 AC6 gate)', () {
    test('no fence is well-formed', () {
      expect(frontmatterWellFormed('just a body\n'), isTrue);
    });

    test('a valid yaml map fence is well-formed', () {
      expect(frontmatterWellFormed('---\nname: x\n---\nbody'), isTrue);
    });

    test('an opened fence that is never closed is malformed (torn write)',
        () {
      expect(frontmatterWellFormed('---\nname: x\n'), isFalse);
    });

    test('unparseable yaml is malformed', () {
      expect(frontmatterWellFormed('---\n\ta: b\n---\nbody'), isFalse);
    });

    test('a yaml list fence is malformed (no map to read metadata from)',
        () {
      expect(frontmatterWellFormed('---\n- a\n- b\n---\nbody'), isFalse);
    });

    // gh-1440 review: an empty (or comment-only) fence is well-formed
    // "no metadata" — the skill loads with the directory fallback name
    // and an empty description, exactly like pre-gh-1440 discovery.
    test('an empty fence is well-formed "no metadata"', () {
      expect(frontmatterWellFormed('---\n---\nbody'), isTrue);
    });

    test('a comment-only fence is well-formed "no metadata"', () {
      expect(frontmatterWellFormed('---\n# note\n---\nbody'), isTrue);
    });
  });
}
