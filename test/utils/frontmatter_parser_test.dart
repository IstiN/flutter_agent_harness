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
}
