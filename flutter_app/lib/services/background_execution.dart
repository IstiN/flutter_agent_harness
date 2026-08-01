// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the IO implementation uses the `fah/background`
/// method channel (iOS `beginBackgroundTask`); everywhere else the stub is
/// a no-op (web has no such concept).
export 'background_execution_stub.dart'
    if (dart.library.io) 'background_execution_io.dart';
