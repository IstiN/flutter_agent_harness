/// Conditional facade for the FFI-backed SQLite engine.
///
/// The real engine (`sqlite3_engine_io.dart`) opens databases through
/// `package:sqlite3` (FFI), which has no web build. The browser gets
/// `sqlite3_engine_stub.dart`, whose `openReadOnly` answers with a clean
/// `UnsupportedError` — web hosts construct the `read` tool without an
/// engine (see `sqlite_reader.dart`).
library;

export 'sqlite3_engine_io.dart'
    if (dart.library.js_interop) 'sqlite3_engine_stub.dart';
