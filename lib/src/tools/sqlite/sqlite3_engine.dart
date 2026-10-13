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
  /// Creates an engine. [openOverride] replaces the real `sqlite3.open`
  /// (test seam for simulating native-assets library-load failures).
  const Sqlite3Engine({SqliteOpen? openOverride})
    : _openOverride = openOverride;

  final SqliteOpen? _openOverride;

  @override
  SqliteDatabase openReadOnly(String path) {
    try {
      return (_openOverride ?? _openBundledLibrary)(path);
    } on ArgumentError catch (error) {
      // gh-1574: a missing bundled libsqlite3 (installers must place it in
      // <exe_dir>/../lib) surfaces as the ffi resolver's ArgumentError —
      // degrade to the clean sqlite-unavailable note instead of the raw FFI
      // dump. A Dart-level system-library fallback is not possible with
      // package:sqlite3 native assets (bindings resolve via the build-time
      // asset mapping; no loader override), so the repair is the layout.
      if (isSqliteDynamicLibraryLoadFailure(error)) {
        throw StateError(sqliteUnavailableMessage(path));
      }
      rethrow;
    }
  }

  static SqliteDatabase _openBundledLibrary(String path) {
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
      statement.close();
    }
  }

  @override
  int parameterCount(String sql) {
    final statement = _db.prepare(sql);
    try {
      return statement.parameterCount;
    } finally {
      statement.close();
    }
  }

  @override
  void execute(String sql) {
    _db.execute(sql);
  }

  @override
  void close() {
    _db.close();
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
