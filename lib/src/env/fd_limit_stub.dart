/// The web / non-POSIX stub of the gh-2415 fd-limit raise: no
/// `RLIMIT_NOFILE` semantics, so nothing to read and nothing to raise.
library;

import 'fd_limit.dart';

/// No backend on this host.
FdLimitBackend? systemFdLimitBackend() => null;

/// A no-op answering null (nothing was raised).
FdLimitOutcome? raiseFdLimitOnce() => null;
