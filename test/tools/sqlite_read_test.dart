import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

void main() {
  group('parseSqlitePathCandidates', () {
    test('splits database from table and query', () {
      final candidates = parseSqlitePathCandidates('data.db:users?limit=5');
      expect(candidates, hasLength(1));
      expect(candidates.single.sqlitePath, 'data.db');
      expect(candidates.single.subPath, 'users');
      expect(candidates.single.queryString, 'limit=5');
    });

    test('handles bare paths and every extension', () {
      expect(parseSqlitePathCandidates('data.db').single.subPath, '');
      expect(parseSqlitePathCandidates('data.db').single.queryString, '');
      for (final path in ['a.db', 'a.db3', 'a.sqlite', 'a.sqlite3:t']) {
        expect(parseSqlitePathCandidates(path), isNotEmpty, reason: path);
      }
      expect(parseSqlitePathCandidates('a.dbx'), isEmpty);
      expect(parseSqlitePathCandidates('a.txt'), isEmpty);
    });

    test('prefers the longest database prefix', () {
      final candidates = parseSqlitePathCandidates('a.db:b.db:t');
      expect(candidates.first.sqlitePath, 'a.db:b.db');
      expect(candidates.last.sqlitePath, 'a.db');
    });

    test('splits at the first question mark only', () {
      final candidates = parseSqlitePathCandidates('a.db?t=1&u=2');
      expect(candidates.single.subPath, '');
      expect(candidates.single.queryString, 't=1&u=2');
    });
  });

  group('parseSqliteSelector', () {
    test('bare path lists tables', () {
      expect(parseSqliteSelector('', ''), isA<SqliteListSelector>());
    });

    test('table alone renders the schema', () {
      final selector = parseSqliteSelector('users', '');
      expect(selector, isA<SqliteSchemaSelector>());
      expect((selector as SqliteSchemaSelector).table, 'users');
      expect(selector.sampleLimit, defaultSqliteSchemaSampleLimit);
    });

    test('table:key is a row lookup', () {
      final selector = parseSqliteSelector('users:42', '');
      expect(selector, isA<SqliteRowSelector>());
      expect((selector as SqliteRowSelector).key, '42');
    });

    test('query parameters page a table', () {
      final selector = parseSqliteSelector(
        'users',
        'limit=10&offset=20&order=age:desc&where=age > 30',
      );
      expect(selector, isA<SqliteQuerySelector>());
      final query = selector as SqliteQuerySelector;
      expect(query.limit, 10);
      expect(query.offset, 20);
      expect(query.order, 'age:desc');
      expect(query.where, 'age > 30');
    });

    test('q= runs a raw query', () {
      final selector = parseSqliteSelector('', 'q=SELECT 1');
      expect(selector, isA<SqliteRawSelector>());
      expect((selector as SqliteRawSelector).sql, 'SELECT 1');
    });

    test('rejects raw queries combined with anything else', () {
      expect(
        () => parseSqliteSelector('users', 'q=SELECT 1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot be combined with table selectors'),
          ),
        ),
      );
      expect(
        () => parseSqliteSelector('', 'q=SELECT 1&limit=5'),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects an empty q', () {
      expect(
        () => parseSqliteSelector('', 'q='),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "SQLite query parameter 'q' cannot be empty",
          ),
        ),
      );
    });

    test('rejects parameters without a table', () {
      expect(
        () => parseSqliteSelector('', 'limit=5'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('require a table selector or q=SELECT'),
          ),
        ),
      );
    });

    test('rejects row lookups combined with parameters', () {
      expect(
        () => parseSqliteSelector('users:42', 'limit=5'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('row lookups cannot be combined'),
          ),
        ),
      );
    });

    test('rejects unknown parameters', () {
      expect(
        () => parseSqliteSelector('users', 'foo=1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "Unsupported SQLite query parameter 'foo'",
          ),
        ),
      );
    });

    test('rejects invalid limit and offset values', () {
      expect(
        () => parseSqliteSelector('users', 'limit=abc'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "SQLite limit must be a positive integer; got 'abc'",
          ),
        ),
      );
      expect(
        () => parseSqliteSelector('users', 'offset=-1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "SQLite offset must be a non-negative integer; got '-1'",
          ),
        ),
      );
    });

    test('caps the limit at the maximum', () {
      final selector = parseSqliteSelector('users', 'limit=9999');
      expect((selector as SqliteQuerySelector).limit, maxSqliteQueryLimit);
    });

    test('strips leading colons from the sub path', () {
      // `data.db::users` — the candidate splitter also strips, so this is
      // just belt-and-braces parity with omp.
      final selector = parseSqliteSelector('::users', '');
      expect((selector as SqliteSchemaSelector).table, 'users');
    });

    group('where validation', () {
      test('rejects statement terminators and comments', () {
        expect(
          () => parseSqliteSelector('users', 'where=1=1; DROP TABLE users'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('must not contain comments or statement terminators'),
            ),
          ),
        );
        expect(
          () => parseSqliteSelector('users', 'where=1=1 --'),
          throwsA(isA<StateError>()),
        );
        expect(
          () => parseSqliteSelector('users', 'where=1=1 /*'),
          throwsA(isA<StateError>()),
        );
      });

      test('rejects control keywords', () {
        expect(
          () => parseSqliteSelector('users', 'where=1=1 LIMIT 5'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('must not contain LIMIT/OFFSET/UNION'),
            ),
          ),
        );
        expect(
          () => parseSqliteSelector('users', 'where=1=1 UNION SELECT 1'),
          throwsA(isA<StateError>()),
        );
      });

      test('allows keywords inside string literals', () {
        final selector = parseSqliteSelector(
          'users',
          "where=name = 'limit; drop'",
        );
        expect((selector as SqliteQuerySelector).where, "name = 'limit; drop'");
      });
    });
  });

  group('truncateSqliteWidth', () {
    test('keeps short values intact', () {
      expect(truncateSqliteWidth('abc', 5), 'abc');
    });

    test('truncates with an ellipsis', () {
      expect(truncateSqliteWidth('abcdef', 4), 'abc…');
      expect(truncateSqliteWidth('abcdef', 1), '…');
    });
  });

  group('stringifySqliteValue', () {
    test('renders null, numbers, strings, and blobs', () {
      expect(stringifySqliteValue(null), 'NULL');
      expect(stringifySqliteValue(42), '42');
      expect(stringifySqliteValue(1.5), '1.5');
      expect(stringifySqliteValue('hi'), 'hi');
      expect(
        stringifySqliteValue(Uint8List.fromList(const [1, 2, 3])),
        '<BLOB 3B>',
      );
    });
  });

  group('buildSqliteAsciiTable', () {
    test('renders an aligned table', () {
      final table = buildSqliteAsciiTable(
        ['id', 'name'],
        [
          {'id': 1, 'name': 'alice'},
          {'id': 2, 'name': 'bob'},
        ],
      );
      expect(
        table,
        '| id  | name  |\n'
        '| --- | ----- |\n'
        '| 1   | alice |\n'
        '| 2   | bob   |',
      );
    });

    test('renders an empty result', () {
      expect(buildSqliteAsciiTable(['id'], []), '| id  |\n| --- |\n(no rows)');
      expect(buildSqliteAsciiTable([], []), '(no rows)');
      expect(
        buildSqliteAsciiTable([], [
          {'a': 1},
        ]),
        '(rows returned without named columns)',
      );
    });

    test('caps cell width at the column maximum', () {
      final table = buildSqliteAsciiTable(
        ['v'],
        [
          {'v': 'x' * 100},
        ],
      );
      expect(table, contains('…'));
      for (final line in table.split('\n')) {
        expect(line.length, lessThanOrEqualTo(120));
      }
    });

    test('falls back to vertical blocks beyond 19 columns', () {
      final columns = [for (var i = 1; i <= 21; i++) 'c$i'];
      final row = {for (final column in columns) column: 'v'};
      final table = buildSqliteAsciiTable(columns, [row]);
      expect(table, contains('── Row 1 ──'));
      expect(table, contains('c21: v'));
    });
  });

  group('render helpers', () {
    test('renderSqliteTableList', () {
      expect(renderSqliteTableList([]), '(no tables)');
      expect(
        renderSqliteTableList(const [
          SqliteTableSummary('users', 3),
          SqliteTableSummary('big', 50000, exact: false),
        ]),
        'users (3 rows)\nbig (50000+ rows)',
      );
    });

    test('renderSqliteSchema appends the sample table', () {
      final output = renderSqliteSchema(
        'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
        const SqliteRows(
          columns: ['id', 'name'],
          rows: [
            {'id': 1, 'name': 'alice'},
          ],
        ),
      );
      expect(output, startsWith('CREATE TABLE users'));
      expect(output, contains('\n\nSample rows:\n| id  | name  |'));
    });

    test('renderSqliteRow lists column values', () {
      expect(renderSqliteRow(const {}), '(no columns)');
      expect(
        renderSqliteRow(const {'id': 1, 'name': 'alice'}),
        'id: 1\nname: alice',
      );
    });

    test('renderSqliteTable adds the continuation note', () {
      final output = renderSqliteTable(
        ['id'],
        [
          {'id': 1},
          {'id': 2},
        ],
        totalCount: 5,
        offset: 0,
        limit: 2,
        table: 'users',
      );
      expect(
        output,
        endsWith(
          '\n[3 more rows; append :users?limit=2&offset=2 to the database '
          'path to continue]',
        ),
      );
    });
  });

  group('readFileTool without a SQLite engine', () {
    test('returns a clean not-supported note', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('data.db', 'not really a database');
      final tool = readFileTool(env);
      final result = await tool.execute({'path': 'data.db'}, null, null);
      expect(
        _text(result),
        contains(
          'SQLite database reads are not supported in this '
          'environment',
        ),
      );
      expect(_text(result), contains('data.db was not opened'));
    });

    test('selector errors still surface before the engine check', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      await env.writeFile('data.db', 'x');
      final tool = readFileTool(env);
      expect(
        tool.execute({'path': 'data.db:users?foo=1'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("Unsupported SQLite query parameter 'foo'"),
          ),
        ),
      );
    });
  });
}
