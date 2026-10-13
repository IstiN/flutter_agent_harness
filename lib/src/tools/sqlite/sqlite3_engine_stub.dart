/// Web stub for `sqlite3_engine.dart` (FFI-backed `package:sqlite3`).
///
/// `dart:ffi`/`package:sqlite3` do not compile on the web; `lib/io.dart`
/// conditionally exports this stub there (`if (dart.library.io)`). Web hosts
/// construct the `read` tool without an engine and get a clean "not
/// supported" note for SQLite paths — mirroring the core package contract
/// documented in `sqlite_reader.dart`.
library;

import 'sqlite_reader.dart';

/// A [SqliteEngine] that is never usable on the web.
final class Sqlite3Engine implements SqliteEngine {
  /// Creates an engine. [openOverride] and [layoutRepair] are accepted for
  /// API parity with the FFI engine; the web engine never opens a database.
  final SqliteOpen? openOverride;

  final bool Function()? layoutRepair;

  const Sqlite3Engine({this.openOverride, this.layoutRepair});

  @override
  SqliteDatabase openReadOnly(String path) => throw UnsupportedError(
    'Sqlite3Engine requires dart:ffi (package:sqlite3), which is not '
    'available on the web',
  );
}

/// Web stub for the gh-1574 layout repair (`repairStaleSqliteBundleLayout`
/// parity with the FFI engine): there is no installed-binary layout to heal
/// on the web.
bool repairStaleSqliteBundleLayout({String? executablePath}) => false;
