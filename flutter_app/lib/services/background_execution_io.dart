// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/services.dart';

import 'package:fa/services/app_log.dart';

/// iOS extended background execution over the `fah/background` method
/// channel (AppDelegate.swift): wraps `UIApplication.beginBackgroundTask`
/// so an in-flight agent run gets the legal ~30 s of extra time when the
/// user backgrounds the app mid-stream. Answers are best-effort — a
/// channel failure must never break a run.
abstract final class BackgroundExecution {
  static const _channel = MethodChannel('fah/background');

  /// Starts a background task named [name]; returns its id for [end], or
  /// null when the system refused (or the call failed).
  static Future<int?> begin(String name) async {
    try {
      final id = await _channel.invokeMethod<int>('begin', {'name': name});
      return id != null && id >= 0 ? id : null;
    } on Object catch (e) {
      AppLog.i('background', 'begin failed: $e');
      return null;
    }
  }

  /// Ends the task started by [begin] (null-safe).
  static Future<void> end(int? id) async {
    if (id == null) return;
    try {
      await _channel.invokeMethod<void>('end', {'id': id});
    } on Object catch (e) {
      AppLog.i('background', 'end failed: $e');
    }
  }

  /// Keeps the screen awake while [on] (iOS `isIdleTimerDisabled`, Android
  /// `FLAG_KEEP_SCREEN_ON`): an in-flight agent run must not let the phone
  /// lock itself mid-stream. Best-effort — a channel failure never breaks
  /// the run (macOS/web have no such toggle).
  static Future<void> setScreenAwake(bool on) async {
    try {
      await _channel.invokeMethod<void>('setIdleTimerDisabled', {
        'disabled': on,
      });
    } on Object catch (e) {
      AppLog.i('background', 'setIdleTimerDisabled failed: $e');
    }
  }
}
