// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Contract for the iOS Live Activity (Dynamic Island + lock screen) that
/// mirrors an agent run's status: [start] when a run begins, [update] on
/// every status change (and once with the final done/error state), [end]
/// to dismiss. Every call is best-effort — a failure must never break a
/// run.
abstract final class LiveActivity {
  /// Starts the activity for a run; no-op when unsupported.
  static Future<void> start({
    required String sessionTitle,
    required String statusText,
  }) => Future.value();

  /// Pushes a new status to the running activity (no-op when none).
  static Future<void> update({
    required String statusText,
    bool isError = false,
    bool isDone = false,
  }) => Future.value();

  /// Ends the activity (immediate dismissal).
  static Future<void> end() => Future.value();
}
