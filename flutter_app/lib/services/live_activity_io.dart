// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'package:fa/services/app_log.dart';

/// iOS Live Activity over the `fah/live_activity` method channel
/// (AppDelegate.swift): shows the agent run's status on the Dynamic Island
/// and the lock screen so a backgrounded run stays visible. Answers are
/// best-effort — a channel failure must never break a run. macOS also has
/// `dart:io`, so every entry point gates on [Platform.isIOS].
abstract final class LiveActivity {
  static const _channel = MethodChannel('fah/live_activity');

  /// Starts the activity for a run; silently skipped when the OS refuses
  /// (Live Activities disabled, iOS < 16.2) or the call fails.
  static Future<void> start({
    required String sessionTitle,
    required String statusText,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<bool>('start', {
        'sessionTitle': sessionTitle,
        'statusText': statusText,
      });
    } on Object catch (e) {
      AppLog.i('live_activity', 'start failed: $e');
    }
  }

  /// Pushes a new status to the running activity (no-op when none).
  static Future<void> update({
    required String statusText,
    bool isError = false,
    bool isDone = false,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('update', {
        'statusText': statusText,
        'isError': isError,
        'isDone': isDone,
      });
    } on Object catch (e) {
      AppLog.i('live_activity', 'update failed: $e');
    }
  }

  /// Ends the activity (immediate dismissal).
  static Future<void> end() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('end');
    } on Object catch (e) {
      AppLog.i('live_activity', 'end failed: $e');
    }
  }
}
