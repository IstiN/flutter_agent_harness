/// Host-shell flavour probe (gh-2102 review): the `/handoff` editor command
/// must quote the digest path for the shell the env's foreground `exec`
/// actually runs it under. Platform glue only — `dart:io` behind the
/// web-safe conditional-import pattern; web builds get
/// `host_shell_stub.dart`.
library;

import 'dart:io';

/// Whether the host shell is Windows `cmd` (`LocalShell` routes Windows
/// commands through `cmd /c`), where single quotes are LITERAL characters —
/// POSIX single-quote wrapping never reaches the editor argv there, so the
/// quoting must switch to double quotes.
bool get hostShellIsWindows => Platform.isWindows;
