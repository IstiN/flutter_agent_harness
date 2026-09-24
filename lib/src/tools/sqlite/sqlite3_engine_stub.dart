/// Web stub for the SQLite engine: browsers cannot open local database
/// files, so every open answers with [UnsupportedError] — the `read`
/// tool renders its standard "not supported on this platform" note.
library;

import 'sqlite_reader.dart';

/// A [SqliteEngine] that never opens on the web.
final class Sqlite3Engine implements SqliteEngine {
  /// Creates the stub engine.
  const Sqlite3Engine();

  @override
  SqliteDatabase openReadOnly(String path) => throw UnsupportedError(
    'SQLite reads are not supported on the web platform.',
  );
}
