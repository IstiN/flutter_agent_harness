/// FFI-backed [SqliteEngine] on `package:sqlite3`, for VM/desktop/mobile
/// hosts. Exported only from `lib/io.dart` (the `dart:io` entry point) so
/// the core library stays pure Dart and web-compilable; web hosts construct
/// the `read` tool without an engine and get a clean "not supported" note
/// for SQLite paths.
library;

import 'dart:typed_data';

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'sqlite_reader.dart';

/// One-time successor-side layout repair for installs made before gh-1574
/// was fixed (gh-1574 r2 review): the pre-fix installers — and one `fa
/// update` run by a pre-fix binary, whose baked-in copy code still targets
/// the old layout — leave the bundled libraries in `<exe_dir>/lib`,
/// which nothing reads. Moves every `libsqlite3.*` found there into the
/// `<exe_dir>/../lib/` directory the native-assets resolver actually reads,
/// reporting whether anything moved so the caller can retry the load.
///
/// Best-effort and conservative: never throws, never clobbers a file that
/// already exists at the target, touches only `libsqlite3.*` names (a dev
/// run's "exe" is the Dart VM, whose directories must not be disturbed),
/// and returns false on any surprise so the real load error still surfaces.
bool repairStaleSqliteBundleLayout({String? executablePath}) {
  try {
    final exeDir = File(
      executablePath ?? Platform.resolvedExecutable,
    ).parent.path;
    final staleDir = Directory('$exeDir${Platform.pathSeparator}lib');
    if (!staleDir.existsSync()) return false;
    final targetDirPath =
        '$exeDir${Platform.pathSeparator}..${Platform.pathSeparator}lib';
    if (_normalizeDirPath(staleDir.path) == _normalizeDirPath(targetDirPath)) {
      return false;
    }
    var moved = false;
    for (final entity in staleDir.listSync()) {
      if (entity is! File) continue;
      final segments = entity.uri.pathSegments.where((s) => s.isNotEmpty);
      final name = segments.isEmpty ? '' : segments.last;
      if (!name.startsWith('libsqlite3.')) continue;
      final target = File('$targetDirPath/$name');
      if (target.existsSync()) continue;
      target.parent.createSync(recursive: true);
      try {
        entity.renameSync(target.path);
      } on FileSystemException {
        // Cross-device rename: fall back to copy + delete.
        entity.copySync(target.path);
        entity.deleteSync();
      }
      moved = true;
    }
    return moved;
  } catch (_) {
    return false;
  }
}

/// [path] with `.`/`..` segments and duplicate separators resolved — used
/// only for equality checks between two layout paths.
String _normalizeDirPath(String path) {
  final parts = <String>[];
  for (final part in path.split(Platform.pathSeparator)) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty && parts.last != '..') {
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.join(Platform.pathSeparator);
}

/// A [SqliteEngine] opening databases through `package:sqlite3` (FFI).
final class Sqlite3Engine implements SqliteEngine {
  /// Creates an engine. [openOverride] replaces the real `sqlite3.open`
  /// (test seam for simulating native-assets library-load failures);
  /// [layoutRepair] replaces [repairStaleSqliteBundleLayout] (test seam for
  /// the successor-side layout repair).
  final SqliteOpen? openOverride;

  final bool Function()? layoutRepair;

  const Sqlite3Engine({this.openOverride, this.layoutRepair});

  @override
  SqliteDatabase openReadOnly(String path) {
    try {
      return (openOverride ?? _openBundledLibrary)(path);
    } on ArgumentError catch (error) {
      // gh-1574: a missing bundled libsqlite3 (installers must place it in
      // <exe_dir>/../lib) surfaces as the ffi resolver's ArgumentError —
      // degrade to the clean sqlite-unavailable note instead of the raw FFI
      // dump. A Dart-level system-library fallback is not possible with
      // package:sqlite3 native assets (bindings resolve via the build-time
      // asset mapping; no loader override), so the repair is the layout.
      if (!isSqliteDynamicLibraryLoadFailure(error)) rethrow;
      // gh-1574 r2: heal pre-fix installs on the successor side — move the
      // stale <exe_dir>/libsqlite3.* into <exe_dir>/../lib and retry the
      // load once, so the first SQLite read on an updated binary repairs
      // the layout instead of demanding a second `fa update`.
      if ((layoutRepair ?? repairStaleSqliteBundleLayout)()) {
        try {
          return (openOverride ?? _openBundledLibrary)(path);
        } on ArgumentError catch (retryError) {
          if (!isSqliteDynamicLibraryLoadFailure(retryError)) rethrow;
        }
      }
      throw StateError(sqliteUnavailableMessage(path));
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
