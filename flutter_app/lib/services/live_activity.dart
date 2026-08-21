// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the IO implementation uses the `fah/live_activity`
/// method channel (iOS ActivityKit Live Activity); everywhere else the stub
/// is a no-op (web and desktop have no such concept).
library;

export 'live_activity_stub.dart' if (dart.library.io) 'live_activity_io.dart';
