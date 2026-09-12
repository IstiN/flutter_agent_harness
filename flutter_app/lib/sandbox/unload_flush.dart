// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/sandbox/unload_flush_stub.dart'
    if (dart.library.html) 'package:fa/sandbox/unload_flush_web.dart';

/// Re-exported [bindUnloadFlush]: wires a [PersistentWebExecutionEnv]'s
/// best-effort flush to the browser's page-unload signals on web; a no-op
/// everywhere else.
