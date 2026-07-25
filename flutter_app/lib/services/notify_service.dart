// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:uuid/uuid.dart';

export 'package:fa/services/notify_service_stub.dart'
    if (dart.library.io) 'package:fa/services/notify_service_io.dart';

/// Local user notifications scheduled by the app (UNUserNotificationCenter
/// on macOS/iOS). LOCAL only — no remote pushes, no background modes.
///
/// Use [createNotifyService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/notify` method channel on IO
/// platforms, a never-available stub on web. Tests inject fakes.
abstract interface class NotifyApi {
  /// Whether this platform can post local notifications at all.
  Future<bool> get isAvailable;

  /// Asks the OS for notification access (prompts once, then returns the
  /// stored decision). True when notifications may be posted.
  Future<bool> requestAccess();

  /// Schedules a local notification and returns its id. [delaySeconds]
  /// absent/zero fires immediately; a positive delay schedules a one-shot
  /// trigger (never repeating). [id] overrides the generated identifier —
  /// reusing an id replaces the pending request with that id.
  Future<String> schedule({
    required String title,
    String? body,
    String? id,
    double? delaySeconds,
  });

  /// Cancels the scheduled (or already-delivered) notification with [id].
  Future<void> cancel({required String id});

  /// Cancels every scheduled and delivered notification of this app.
  Future<void> cancelAll();
}

/// The default id generator for [NotifyApi.schedule] callers that don't
/// pass an explicit id (the channel also generates one natively — the
/// Dart-side id exists so callers always know the id up front).
String newNotificationId() => 'fa-notify-${const Uuid().v4()}';
