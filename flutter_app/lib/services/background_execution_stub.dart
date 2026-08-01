// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Contract for extended background execution (iOS `beginBackgroundTask`):
/// [begin] asks the OS for extra time to finish an in-flight agent run
/// when the app is backgrounded (~30 s typically); [end] releases it.
abstract final class BackgroundExecution {
  /// Starts a background task named [name]; returns its id for [end], or
  /// null when unsupported.
  static Future<int?> begin(String name) => Future.value();

  /// Ends the task started by [begin] (null-safe).
  static Future<void> end(int? id) => Future.value();
}
