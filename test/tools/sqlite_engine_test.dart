import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

/// The dart:ffi resolver's failure for a missing bundled libsqlite3, as
/// reported on macOS (gh-1574 ticket) — installed at `~/.local/bin/fa`, the
/// native-assets resolver looks in `~/.local/lib/` and finds nothing.
final _macMissingDylibError = ArgumentError(
  "Couldn't resolve native function 'sqlite3_initialize' in "
  "'package:sqlite3/src/ffi/libsqlite3.g.dart' : Failed to load dynamic "
  "library '/Users/someone/.local/lib/libsqlite3.dylib' (no such file)",
);

/// The same failure on Linux (`libsqlite3.so`).
final _linuxMissingDylibError = ArgumentError(
  "Couldn't resolve native function 'sqlite3_initialize' in "
  "'package:sqlite3/src/ffi/libsqlite3.g.dart' : Failed to load dynamic "
  "library '../lib/libsqlite3.so' relative to '/usr/local/bin/fa': Failed "
  "to load dynamic library '/usr/local/lib/libsqlite3.so': cannot open "
  'shared object file: No such file or directory',
);

/// A do-nothing [SqliteDatabase] for engine retry tests.
final class _StubDb implements SqliteDatabase {
  const _StubDb();

  @override
  SqliteRows select(
    String sql, {
    List<Object?> parameters = const [],
    int? maxRows,
  }) => const SqliteRows(columns: [], rows: []);

  @override
  int parameterCount(String sql) => 0;

  @override
  void execute(String sql) {}

  @override
  void close() {}
}

void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;
  late AgentTool tool;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('harness-sqlite-test-');
    final db = sqlite3.open('${tempDir.path}/data.db');
    db.execute(
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)',
    );
    db.execute(
      "INSERT INTO users (name, age) VALUES ('alice', 34), ('bob', 28), "
      "('carol', 41)",
    );
    db.execute('CREATE TABLE logs (message TEXT)');
    db.execute("INSERT INTO logs (message) VALUES ('first'), ('second')");
    db.execute('CREATE TABLE blobs (data BLOB)');
    db.execute('INSERT INTO blobs (data) VALUES (?)', [
      [1, 2, 3, 4],
    ]);
    db.execute('CREATE TABLE big (id INTEGER PRIMARY KEY, val TEXT)');
    for (var i = 1; i <= 30; i++) {
      db.execute('INSERT INTO big (val) VALUES (?)', ['row$i']);
    }
    db.close();

    env = LocalExecutionEnv(cwd: tempDir.path);
    tool = readFileTool(env, sqlite: const Sqlite3Engine());
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('lists tables with row counts', () async {
    final result = await tool.execute({'path': 'data.db'}, null, null);
    expect(
      _text(result),
      'big (30 rows)\nblobs (1 rows)\nlogs (2 rows)\nusers (3 rows)',
    );
  });

  test('renders a table schema with sample rows', () async {
    final result = await tool.execute({'path': 'data.db:users'}, null, null);
    final text = _text(result);
    expect(text, contains('CREATE TABLE users'));
    expect(text, contains('Sample rows:'));
    expect(text, contains('alice'));
    expect(text, contains('carol'));
  });

  test('the schema sample note points at paged reads', () async {
    final result = await tool.execute({'path': 'data.db:big'}, null, null);
    expect(
      _text(result),
      contains(
        '[25 more rows; append :big?limit=20&offset=5 to the database '
        'path to continue]',
      ),
    );
  });

  test('looks a row up by primary key', () async {
    final result = await tool.execute({'path': 'data.db:users:2'}, null, null);
    expect(_text(result), 'id: 2\nname: bob\nage: 28');
  });

  test('falls back to rowid for tables without a primary key', () async {
    final result = await tool.execute({'path': 'data.db:logs:2'}, null, null);
    expect(_text(result), 'message: second');
  });

  test('a missing row says so', () async {
    final result = await tool.execute({'path': 'data.db:users:99'}, null, null);
    expect(_text(result), "No row found in table 'users' for key '99'.");
  });

  test('a non-integer key on an integer primary key throws', () async {
    expect(
      tool.execute({'path': 'data.db:users:abc'}, null, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains("must be an integer; got 'abc'"),
        ),
      ),
    );
  });

  test('pages a table with limit/offset and a continuation note', () async {
    final page1 = await tool.execute(
      {'path': 'data.db:users?limit=2'},
      null,
      null,
    );
    final text1 = _text(page1);
    expect(text1, contains('alice'));
    expect(text1, isNot(contains('carol')));
    expect(
      text1,
      contains(
        '[1 more rows; append :users?limit=2&offset=2 to the database '
        'path to continue]',
      ),
    );

    final page2 = await tool.execute(
      {'path': 'data.db:users?limit=2&offset=2'},
      null,
      null,
    );
    final text2 = _text(page2);
    expect(text2, contains('carol'));
    expect(text2, isNot(contains('to continue]')));
  });

  test('orders and filters a paged table', () async {
    final result = await tool.execute(
      {'path': 'data.db:users?order=age:desc&where=age > 30'},
      null,
      null,
    );
    final text = _text(result);
    expect(text, contains('carol'));
    expect(text, contains('alice'));
    expect(text, isNot(contains('bob')));
    expect(text.indexOf('carol'), lessThan(text.indexOf('alice')));
  });

  test('rejects an unknown order column', () async {
    expect(
      tool.execute({'path': 'data.db:users?order=nope'}, null, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          "SQLite order column 'nope' not found in table schema",
        ),
      ),
    );
  });

  test('runs a raw read-only query', () async {
    final result = await tool.execute(
      {
        'path':
            'data.db?q=SELECT name, age FROM users WHERE age >= 34 ORDER BY age',
      },
      null,
      null,
    );
    final text = _text(result);
    expect(text, contains('alice'));
    expect(text, contains('carol'));
    expect(text, isNot(contains('bob')));
  });

  test('rejects bound parameters in raw queries', () async {
    expect(
      tool.execute(
        {'path': 'data.db?q=SELECT * FROM users WHERE id = ?'},
        null,
        null,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'SQLite raw queries do not support bound parameters',
        ),
      ),
    );
  });

  test('renders blob cells as size placeholders', () async {
    final result = await tool.execute({'path': 'data.db:blobs'}, null, null);
    expect(_text(result), contains('<BLOB 4B>'));
  });

  test('a missing table errors with omp’s message', () async {
    expect(
      tool.execute({'path': 'data.db:nope'}, null, null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          "SQLite table 'nope' not found",
        ),
      ),
    );
  });

  test('a non-database file fails cleanly', () async {
    File('${tempDir.path}/notes.db').writeAsStringSync('plain text');
    expect(
      tool.execute({'path': 'notes.db'}, null, null),
      throwsA(isA<StateError>()),
    );
  });

  test('looks rows up by a REAL primary key, coercing numeric keys', () async {
    final db = sqlite3.open('${tempDir.path}/real.db');
    db.execute('CREATE TABLE prices (id REAL PRIMARY KEY, label TEXT)');
    db.execute("INSERT INTO prices (id, label) VALUES (1.5, 'a'), (2.5, 'b')");
    db.close();

    final found = await tool.execute(
      {'path': 'real.db:prices:1.5'},
      null,
      null,
    );
    expect(_text(found), 'id: 1.5\nlabel: a');

    // A non-numeric key on a REAL primary key stays a string and matches
    // nothing (omp coerces best-effort instead of throwing).
    final missing = await tool.execute(
      {'path': 'real.db:prices:abc'},
      null,
      null,
    );
    expect(_text(missing), "No row found in table 'prices' for key 'abc'.");
  });

  test('looks rows up by a TEXT primary key without coercion', () async {
    final db = sqlite3.open('${tempDir.path}/text.db');
    db.execute('CREATE TABLE tags (code TEXT PRIMARY KEY, v TEXT)');
    db.execute("INSERT INTO tags (code, v) VALUES ('x1', 'one')");
    db.close();

    final result = await tool.execute({'path': 'text.db:tags:x1'}, null, null);
    expect(_text(result), 'code: x1\nv: one');
  });

  test('raw queries are capped and say how to page', () async {
    final db = sqlite3.open('${tempDir.path}/huge.db');
    db.execute('CREATE TABLE t (v TEXT)');
    final insert = db.prepare('INSERT INTO t (v) VALUES (?)');
    for (var i = 0; i < 1100; i++) {
      insert.execute(['v$i']);
    }
    insert.close();
    db.close();

    final result = await tool.execute(
      {'path': 'huge.db?q=SELECT * FROM t'},
      null,
      null,
    );
    final text = _text(result);
    expect(
      text,
      contains(
        '[Output capped at 1000 rows; add a LIMIT/OFFSET clause to the '
        'query to page through more]',
      ),
    );
  });

  group('missing bundled library degrades cleanly (gh-1574)', () {
    test('the fixtures mirror the real resolver paths, /lib/ included', () {
      // The real ticket error carries the <exe_dir>/../lib component in the
      // resolver's path (`~/.local/libsqlite3.dylib` for `~/.local/bin/fa`);
      // a fixture transcribing it without the /lib/ segment would pin the
      // wrong shape (gh-1574 r2 review).
      expect(
        _macMissingDylibError.message,
        contains('/Users/someone/.local/lib/libsqlite3.dylib'),
      );
      expect(
        _linuxMissingDylibError.message,
        contains('/usr/local/lib/libsqlite3.so'),
      );
    });

    test('the unavailable note shows the correct example path', () {
      final message = sqliteUnavailableMessage('${tempDir.path}/data.db');
      // <exe_dir>/../lib + libsqlite3.dylib for ~/.local/bin/fa is
      // ~/.local/lib/libsqlite3.dylib — the /lib/ segment must be present.
      expect(message, contains('~/.local/lib/libsqlite3.dylib'));
      expect(message, isNot(contains('~/.local/libsqlite3.dylib')));
    });

    test('the ffi resolver failure shape is recognized', () {
      expect(isSqliteDynamicLibraryLoadFailure(_macMissingDylibError), isTrue);
      expect(
        isSqliteDynamicLibraryLoadFailure(_linuxMissingDylibError),
        isTrue,
      );
    });

    test('database-level errors are not misclassified', () {
      expect(
        isSqliteDynamicLibraryLoadFailure(
          ArgumentError.value('x', 'path', 'must not be empty'),
        ),
        isFalse,
      );
      expect(
        isSqliteDynamicLibraryLoadFailure(
          SqliteException(
            extendedResultCode: 26,
            message: 'file is not a database',
          ),
        ),
        isFalse,
      );
      expect(isSqliteDynamicLibraryLoadFailure(StateError('boom')), isFalse);
    });

    test(
      'openReadOnly maps the load failure to a clean sqlite-unavailable note',
      () {
        final engine = Sqlite3Engine(
          openOverride: (path) => throw _macMissingDylibError,
        );
        expect(
          () => engine.openReadOnly('${tempDir.path}/data.db'),
          throwsA(
            isA<StateError>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('SQLite is unavailable'),
                )
                .having(
                  (e) => e.message,
                  'message mentions the repair',
                  contains('fa update'),
                )
                .having(
                  (e) => e.message,
                  'message is not the raw ffi dump',
                  isNot(contains("Couldn't resolve native function")),
                ),
          ),
        );
      },
    );

    test('openReadOnly rethrows non-load failures untouched', () {
      final original = SqliteException(
        extendedResultCode: 26,
        message: 'file is not a database',
      );
      final engine = Sqlite3Engine(openOverride: (path) => throw original);
      expect(
        () => engine.openReadOnly('${tempDir.path}/data.db'),
        throwsA(same(original)),
      );
    });

    test(
      'the read tool surfaces the clean note, not the raw ffi error',
      () async {
        final engine = Sqlite3Engine(
          openOverride: (path) => throw _linuxMissingDylibError,
        );
        final brokenTool = readFileTool(env, sqlite: engine);
        expect(
          brokenTool.execute({'path': 'data.db'}, null, null),
          throwsA(
            isA<StateError>()
                .having((e) => e.message, 'message', contains('unavailable'))
                .having(
                  (e) => e.message,
                  'message is not the raw ffi dump',
                  isNot(contains('libsqlite3.g.dart')),
                ),
          ),
        );
      },
    );
  });

  group('successor-side layout repair (gh-1574 r2)', () {
    late Directory installRoot;
    late Directory binDir;

    setUp(() {
      // Mirrors a flat binary install: <installRoot>/bin/fa with the
      // pre-fix installers' inert <exe_dir>/lib leftovers beside it.
      installRoot = Directory('${tempDir.path}/local')
        ..createSync(recursive: true);
      binDir = Directory('${installRoot.path}/bin')..createSync();
    });

    test(
      'moves stale <exe_dir>/libsqlite3.* into <exe_dir>/../lib and says so',
      () {
        final stale = Directory('${binDir.path}/lib')..createSync();
        File('${stale.path}/libsqlite3.dylib').writeAsStringSync('dylib');
        File('${stale.path}/libsqlite3.so').writeAsStringSync('so');
        File('${stale.path}/unrelated.dylib').writeAsStringSync('other');

        final moved = repairStaleSqliteBundleLayout(
          executablePath: '${binDir.path}/fa',
        );

        expect(moved, isTrue);
        // Where the native-assets resolver reads: <exe_dir>/../lib/<name>.
        expect(
          File('${installRoot.path}/lib/libsqlite3.dylib').readAsStringSync(),
          'dylib',
        );
        expect(
          File('${installRoot.path}/lib/libsqlite3.so').readAsStringSync(),
          'so',
        );
        // Moved, not duplicated.
        expect(File('${stale.path}/libsqlite3.dylib').existsSync(), isFalse);
        expect(File('${stale.path}/libsqlite3.so').existsSync(), isFalse);
        // Unrelated files in the stale directory are left alone.
        expect(File('${stale.path}/unrelated.dylib').existsSync(), isTrue);
      },
    );

    test('no stale <exe_dir>/lib means no repair', () {
      final moved = repairStaleSqliteBundleLayout(
        executablePath: '${binDir.path}/fa',
      );

      expect(moved, isFalse);
      expect(
        File('${installRoot.path}/lib/libsqlite3.dylib').existsSync(),
        isFalse,
      );
    });

    test('never clobbers a lib already present at the target', () {
      final stale = Directory('${binDir.path}/lib')..createSync();
      File('${stale.path}/libsqlite3.dylib').writeAsStringSync('stale');
      final target = File('${installRoot.path}/lib/libsqlite3.dylib');
      target.parent.createSync(recursive: true);
      target.writeAsStringSync('fresh');

      final moved = repairStaleSqliteBundleLayout(
        executablePath: '${binDir.path}/fa',
      );

      expect(moved, isFalse);
      expect(
        File('${installRoot.path}/lib/libsqlite3.dylib').readAsStringSync(),
        'fresh',
      );
      expect(File('${stale.path}/libsqlite3.dylib').existsSync(), isTrue);
    });

    test('a missing executable is a no-op, never a throw', () {
      expect(
        repairStaleSqliteBundleLayout(
          executablePath: '${binDir.path}/definitely-missing',
        ),
        isFalse,
      );
    });

    test('openReadOnly retries the load after a successful repair', () {
      var opens = 0;
      final engine = Sqlite3Engine(
        openOverride: (path) {
          opens++;
          if (opens == 1) throw _macMissingDylibError;
          return const _StubDb();
        },
        layoutRepair: () => true,
      );

      final db = engine.openReadOnly('${tempDir.path}/data.db');
      db.close();
      expect(opens, 2);
    });

    test('a repair that does not heal still degrades to the clean note', () {
      final engine = Sqlite3Engine(
        openOverride: (path) => throw _macMissingDylibError,
        layoutRepair: () => true,
      );

      expect(
        () => engine.openReadOnly('${tempDir.path}/data.db'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('SQLite is unavailable'),
          ),
        ),
      );
    });

    test('a no-op repair degrades without a second load attempt', () {
      var opens = 0;
      final engine = Sqlite3Engine(
        openOverride: (path) {
          opens++;
          throw _macMissingDylibError;
        },
        layoutRepair: () => false,
      );

      expect(
        () => engine.openReadOnly('${tempDir.path}/data.db'),
        throwsA(isA<StateError>()),
      );
      expect(opens, 1);
    });

    test('a non-load failure on the retried load passes through untouched', () {
      final notADatabase = SqliteException(
        extendedResultCode: 26,
        message: 'file is not a database',
      );
      final engine = Sqlite3Engine(
        openOverride: (path) {
          throw notADatabase;
        },
        layoutRepair: () => true,
      );

      expect(
        () => engine.openReadOnly('${tempDir.path}/data.db'),
        throwsA(same(notADatabase)),
      );
    });
  });
}
