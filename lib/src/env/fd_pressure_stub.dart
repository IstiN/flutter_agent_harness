/// The web / non-POSIX stub of the gh-2415 fd-pressure probe: no
/// descriptor table to read, so the bash tool's guard stays off.
library;

import 'fd_pressure.dart';

/// No descriptor table on this host.
FdPressureSnapshot? defaultFdPressureSnapshot() => null;
