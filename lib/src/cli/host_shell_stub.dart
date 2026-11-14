/// Web-safe stub for `host_shell_io.dart` (the host-shell flavour probe the
/// `/handoff` editor command quotes for, gh-2102 review). The real probe
/// reads `Platform.isWindows` — `dart:io` — so web builds of the root
/// library import this file conditionally:
///
/// ```dart
/// import 'host_shell_stub.dart' if (dart.library.io) 'host_shell_io.dart';
/// ```
///
/// On web there is no host shell to quote for.
library;

/// Whether the host shell is Windows `cmd` (commands run through `cmd /c`).
bool get hostShellIsWindows => false;
