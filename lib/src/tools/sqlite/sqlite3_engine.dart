/// FFI-backed [SqliteEngine] on `package:sqlite3`, for VM/desktop/mobile
/// hosts. Exported only from `lib/io.dart` (the `dart:io` entry point) so
/// the core library stays pure Dart and web-compilable; web hosts construct
/// the `read` tool without an engine and get a clean "not supported" note
/// for SQLite paths.
library;

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'sqlite_reader.dart';

/// A [SqliteEngine] opening databases through `package:sqlite3` (FFI).
final class Sqlite3Engine implements SqliteEngine {
  /// Creates an engine.
  const Sqlite3Engine();

  @override
  SqliteDatabase openReadOnly(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout = $sqliteBusyTimeoutMs');
    return _Sqlite3Database(db);
  }
}

final class _Sqlite3Database implements SqliteDatabase {
  _Sqlite3Database(this._db);

  final Database _db;

  @override
  SqliteRows select(
    String sql, {
    List<Object?> parameters = const [],
    int? maxRows,
  }) {
    final statement = _db.prepare(sql);
    try {
      final rows = <Map<String, Object?>>[];
      var truncated = false;
      if (maxRows == null) {
        final resultSet = statement.select(parameters);
        final columnNames = resultSet.columnNames;
        for (final row in resultSet) {
          rows.add(_rowToMap(columnNames, row));
        }
        return SqliteRows(columns: columnNames, rows: rows);
      }
      final cursor = statement.selectCursor(parameters);
      // Column names are only reliable after the first moveNext (sqlite3
      // re-compiles statements on schema change).
      var hasRow = cursor.moveNext();
      final columnNames = cursor.columnNames;
      while (hasRow) {
        if (rows.length >= maxRows) {
          truncated = true;
          break;
        }
        rows.add(_rowToMap(columnNames, cursor.current));
        hasRow = cursor.moveNext();
      }
      return SqliteRows(columns: columnNames, rows: rows, truncated: truncated);
    } finally {
      statement.dispose();
    }
  }

  @override
  int parameterCount(String sql) {
    final statement = _db.prepare(sql);
    try {
      return statement.parameterCount;
    } finally {
      statement.dispose();
    }
  }

  @override
  void execute(String sql) {
    _db.execute(sql);
  }

  @override
  void close() {
    _db.dispose();
  }

  Map<String, Object?> _rowToMap(List<String> columnNames, Row row) {
    return {
      for (var i = 0; i < columnNames.length; i++)
        columnNames[i]: _normalizeValue(row.columnAt(i)),
    };
  }

  Object? _normalizeValue(Object? value) {
    // sqlite3 returns blob values as Uint8List already; keep the conversion
    // defensive so any List<int> still renders as a blob.
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return value;
  }
}
