// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export (issue #199): IO platforms parse session records in
/// background isolates ([IsolateSessionParseExecutor]); web has no
/// `dart:isolate`, so the stub returns `null` and the repo parses inline
/// in pre-chunked batches (the issue's E1 degradation).
library;

export 'session_parse_factory_stub.dart'
    if (dart.library.io) 'session_parse_factory_io.dart';
